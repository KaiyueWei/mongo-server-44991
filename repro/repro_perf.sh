#!/usr/bin/env bash
set -euo pipefail

############################################
# CONFIG
############################################

# MongoDB build root (export to switch versions)
# e.g. export MONGO_HOME=~/mongo-src/mongo-4.2.1
: "${MONGO_HOME:?Must set MONGO_HOME}"

DBPATH="$HOME/data/server44991-db"
PARALLEL_TESTER="$MONGO_HOME/jstests/libs/parallelTester.js"

FLAMEGRAPH_DIR="$HOME/tools/FlameGraph"
RESULTS_DIR="$HOME/mongo-server-44991/results"
VERSION_TAG=$(basename "$MONGO_HOME")

mkdir -p "$RESULTS_DIR"

############################################
# Start mongod
############################################
start_mongod() {
    echo "==> Starting mongod ($VERSION_TAG)"

    rm -rf "$DBPATH"
    mkdir -p "$DBPATH"

    pkill -9 mongod || true

    "$MONGO_HOME/mongod" \
        --dbpath "$DBPATH" \
        --logpath "$DBPATH/mongod.log" \
        --fork \
        --wiredTigerCacheSizeGB 4

    sleep 3
}

############################################
# Insert phase (unprofiled)
############################################
insert_phase() {
    echo "==> Insert phase"

    "$MONGO_HOME/mongo" --quiet --eval "
        load('$PARALLEL_TESTER');

        for (var b = 0; b < 10; b++) {
            var spec = {x: 1, a: 1, _id: 1};
            spec['b' + b] = 1;

            db.c0.createIndex(spec);
            db.c1.createIndex(spec);
            db.c2.createIndex(spec);
            db.c3.createIndex(spec);
            db.c4.createIndex(spec);
        }

        var nthreads = 5;
        var threads = [];

        for (var t = 0; t < nthreads; t++) {
            var thread = new ScopedThread(function(t) {
                var count = 1000000;
                var every = 1000;
                var many = [];
                var x = 'x'.repeat(20);
                var c = db['c' + t];

                for (var i = 0; i < count; i++) {
                    if (i % every === 0 && many.length > 0) {
                        c.insertMany(many);
                        many = [];
                    }
                    many.push({
                        _id: i,
                        x: x,
                        a: 0,
                        b0:0,b1:0,b2:0,b3:0,b4:0,
                        b5:0,b6:0,b7:0,b8:0,b9:0
                    });
                }
            }, t);

            threads.push(thread);
            thread.start();
        }

        threads.forEach(t => t.join());
    "
}

############################################
# Update phase (PROFILED)
############################################
update_phase_perf() {
    echo "==> Update phase (PROFILED) — SERVER-44991"

    perf record -F 99 -g -- \
        "$MONGO_HOME/mongo" --quiet --eval "
            load('$PARALLEL_TESTER');

            var nthreads = 5;
            var threads = [];

            for (var t = 0; t < nthreads; t++) {
                var thread = new ScopedThread(function(t) {
                    var c = db['c' + t];
                    for (var i = 0; i < 20; i++) {
                        c.updateMany(
                            { _id: { \$mod: [100, i] } },
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
# Flamegraph generation
############################################
generate_flamegraph() {
    echo "==> Generating flamegraph"

    perf script > "$RESULTS_DIR/perf_$VERSION_TAG.out"
    "$FLAMEGRAPH_DIR/stackcollapse-perf.pl" \
        "$RESULTS_DIR/perf_$VERSION_TAG.out" \
        > "$RESULTS_DIR/perf_$VERSION_TAG.folded"

    "$FLAMEGRAPH_DIR/flamegraph.pl" \
        "$RESULTS_DIR/perf_$VERSION_TAG.folded" \
        > "$RESULTS_DIR/flamegraph_$VERSION_TAG.svg"

    echo "==> Flamegraph saved to:"
    echo "    $RESULTS_DIR/flamegraph_$VERSION_TAG.svg"
}

############################################
# Main
############################################
start_mongod
insert_phase
update_phase_perf
generate_flamegraph

echo "==> Repro complete for $VERSION_TAG"
