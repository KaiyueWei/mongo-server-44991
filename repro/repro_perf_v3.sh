#!/usr/bin/env bash
set -euo pipefail

############################################
# CONFIG
############################################

MONGO_HOME=${MONGO_HOME:-"$HOME/work/mongo-4.0.13"}
DBPATH="$HOME/data/db"
RESULTS_DIR="$HOME/mongo-server-44991/results"
FLAMEGRAPH_DIR="$HOME/tools/FlameGraph"
PARALLEL_TESTER="$MONGO_HOME/jstests/libs/parallelTester.js"

VERSION_TAG=$(basename "$MONGO_HOME")

mkdir -p "$RESULTS_DIR"

############################################
# HELPERS
############################################

kill_mongod() {
    pkill -9 mongod 2>/dev/null || true
    sleep 1
}

start_mongod() {
    echo "==> Starting mongod ($VERSION_TAG)"
    kill_mongod
    rm -rf "$DBPATH"
    mkdir -p "$DBPATH"

    "$MONGO_HOME/mongod" \
        --dbpath "$DBPATH" \
        --logpath "$DBPATH/mongod.log" \
        --fork \
        --wiredTigerCacheSizeGB 4

    sleep 3
}

mongod_pid() {
    pgrep -n mongod
}

############################################
# PHASE 1: INSERT + INDEX CREATION (NO PERF)
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
            threads.push(new ScopedThread(function(t) {
                var bulk = [];
                var c = db['c' + t];
                for (var i = 0; i < 1000000; i++) {
                    bulk.push({
                        _id: i,
                        x: 'x'.repeat(20),
                        a: 0,
                        b0:0,b1:0,b2:0,b3:0,b4:0,
                        b5:0,b6:0,b7:0,b8:0,b9:0
                    });
                    if (bulk.length === 1000) {
                        c.insertMany(bulk);
                        bulk = [];
                    }
                }
            }, t));
        }

        threads.forEach(t => t.start());
        threads.forEach(t => t.join());
    "
}

############################################
# PHASE 2: UPDATE WORKLOAD (PROFILED)
############################################

update_phase_perf() {
    echo "==> Update phase (PROFILED) — SERVER-44991"

    local PID
    PID=$(mongod_pid)
    echo "Profiling mongod PID: $PID"

    sudo perf record -F 99 -g -p "$PID" -- sleep 30 &
    PERF_PID=$!

    "$MONGO_HOME/mongo" --quiet --eval "
        load('$PARALLEL_TESTER');

        var threads = [];
        for (var t = 0; t < 5; t++) {
            threads.push(new ScopedThread(function(t) {
                var c = db['c' + t];
                for (var i = 0; i < 20; i++) {
                    c.updateMany(
                        { _id: { \$mod: [100, i] } },
                        { \$inc: { a: 1 } }
                    );
                }
            }, t));
        }

        threads.forEach(t => t.start());
        threads.forEach(t => t.join());
    "

    wait "$PERF_PID"
}

############################################
# PHASE 3: FLAMEGRAPH
############################################

generate_flamegraph() {
    echo "==> Generating flamegraph"

    sudo perf script > "$RESULTS_DIR/perf_${VERSION_TAG}.script"

    "$FLAMEGRAPH_DIR/stackcollapse-perf.pl" \
        "$RESULTS_DIR/perf_${VERSION_TAG}.script" \
        > "$RESULTS_DIR/perf_${VERSION_TAG}.folded"

    "$FLAMEGRAPH_DIR/flamegraph.pl" \
        "$RESULTS_DIR/perf_${VERSION_TAG}.folded" \
        > "$RESULTS_DIR/flamegraph_${VERSION_TAG}.svg"

    echo "==> Flamegraph saved to:"
    echo "    $RESULTS_DIR/flamegraph_${VERSION_TAG}.svg"
}

############################################
# RUN
############################################

start_mongod
insert_phase
update_phase_perf
generate_flamegraph

echo "==> Repro complete for $VERSION_TAG"
