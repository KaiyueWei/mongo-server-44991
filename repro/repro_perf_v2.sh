#!/usr/bin/env bash
set -euo pipefail

############################################
# Configuration
############################################

# CHANGE THESE IF NEEDED
MONGO_HOME=${MONGO_HOME:-"$HOME/work/mongo-4.2.1"}
DBPATH="$HOME/data/db"
PARALLEL_TESTER="$MONGO_HOME/jstests/libs/parallelTester.js"

RESULTS_DIR="$HOME/mongo-server-44991/results"
FLAMEGRAPH_DIR="$HOME/tools/FlameGraph"

PERF_FREQ=99
UPDATE_ROUNDS=200        # increase server-side work
THREADS=5

mkdir -p "$RESULTS_DIR"

############################################
# Helpers
############################################

mongod_pid() {
    pgrep -f "$MONGO_HOME/mongod" || true
}

kill_mongod() {
    sudo pkill -9 mongod || true
    sleep 2
}

############################################
# Start mongod
############################################

start_mongod() {
    echo "==> Starting mongod ($(basename "$MONGO_HOME"))"

    kill_mongod
    rm -rf "$DBPATH"
    mkdir -p "$DBPATH"

    "$MONGO_HOME/mongod" \
        --dbpath "$DBPATH" \
        --logpath "$DBPATH/mongod.log" \
        --wiredTigerCacheSizeGB 4 \
        --fork

    sleep 5
}

############################################
# Insert phase (NOT profiled)
############################################

insert_phase() {
    echo "==> Insert phase (data + indexes)"

    "$MONGO_HOME/mongo" --quiet --eval "
        load('$PARALLEL_TESTER');

        for (var b = 0; b < 10; b++) {
            var spec = {x: 1, a: 1, _id: 1};
            spec['b' + b] = 1;
            for (var c = 0; c < 5; c++) {
                db['c' + c].createIndex(spec);
            }
        }

        var threads = [];
        for (var t = 0; t < 5; t++) {
            var thread = new ScopedThread(function(t) {
                var bulk = [];
                var c = db['c' + t];
                var x = 'x'.repeat(20);

                for (var i = 0; i < 1000000; i++) {
                    bulk.push({
                        _id: i,
                        x: x,
                        a: 0,
                        b0:0,b1:0,b2:0,b3:0,b4:0,
                        b5:0,b6:0,b7:0,b8:0,b9:0
                    });

                    if (bulk.length === 1000) {
                        c.insertMany(bulk);
                        bulk = [];
                    }
                }
            }, t);
            threads.push(thread);
            thread.start();
        }
        threads.forEach(t => t.join());
    "
}

############################################
# Update phase (PROFILED — SERVER-44991)
############################################

update_phase_perf() {
    echo "==> Update phase (PROFILED) — SERVER-44991"

    local PID
    PID=$(mongod_pid)

    if [[ -z "$PID" ]]; then
        echo "ERROR: mongod not running"
        exit 1
    fi

    echo "Profiling mongod PID: $PID"

    sudo perf record \
        -F "$PERF_FREQ" \
        -p "$PID" \
        -g \
        --output perf.data \
        -- \
        "$MONGO_HOME/mongo" --quiet --eval "
            load('$PARALLEL_TESTER');

            var threads = [];
            for (var t = 0; t < $THREADS; t++) {
                var thread = new ScopedThread(function(t) {
                    var c = db['c' + t];
                    for (var r = 0; r < $UPDATE_ROUNDS; r++) {
                        c.updateMany(
                            { _id: { \$mod: [100, r] } },
                            { \$inc: { a: 1 } }
                        );
                    }
                }, t);
                threads.push(thread);
                thread.start();
            }
            threads.forEach(t => t.join());
        "
}

############################################
# Flamegraph
############################################

generate_flamegraph() {
    echo "==> Generating flamegraph"

    local version
    version=$("$MONGO_HOME/mongod" --version | grep "db version" | awk '{print $3}')

    sudo perf script > "$RESULTS_DIR/perf_${version}.out"

    "$FLAMEGRAPH_DIR/stackcollapse-perf.pl" \
        "$RESULTS_DIR/perf_${version}.out" \
        > "$RESULTS_DIR/perf_${version}.folded"

    "$FLAMEGRAPH_DIR/flamegraph.pl" \
        "$RESULTS_DIR/perf_${version}.folded" \
        > "$RESULTS_DIR/flamegraph_${version}.svg"

    echo "==> Flamegraph saved to:"
    echo "    $RESULTS_DIR/flamegraph_${version}.svg"
}

############################################
# Main
############################################

start_mongod
insert_phase
update_phase_perf
generate_flamegraph

echo "==> Repro complete for $(basename "$MONGO_HOME")"
