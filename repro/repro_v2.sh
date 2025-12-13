#!/usr/bin/env bash
set -euo pipefail

############################################
# Adjusted paths (YOUR ENV)
############################################
MONGO_HOME="/home/ubuntu/work/mongo-4.2.1"
MONGO_BIN="$MONGO_HOME/mongo"
MONGOD_BIN="$MONGO_HOME/mongod"
PARALLEL_TESTER="$MONGO_HOME/jstests/libs/parallelTester.js"

DBPATH="/home/ubuntu/data/mongo-repro"
LOGPATH="$DBPATH/mongod.log"

############################################
# Start mongod (clean)
############################################
start_mongod() {
    echo "==> Starting mongod"

    rm -rf "$DBPATH"
    mkdir -p "$DBPATH"

    sudo pkill -9 mongod mongo || true

    "$MONGOD_BIN" \
        --dbpath "$DBPATH" \
        --logpath "$LOGPATH" \
        --wiredTigerCacheSizeGB 10 \
        --fork

    sleep 3
}

############################################
# Insert phase (data + indexes)
############################################
insert_phase() {
    echo "==> Insert phase"

    "$MONGO_BIN" --quiet --eval "
        load('$PARALLEL_TESTER');

        // Create many compound indexes
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

                    if (i % 10000 === 0) {
                        print(t, i);
                    }
                }

                if (many.length > 0) {
                    c.insertMany(many);
                }
            }, t);

            threads.push(thread);
            thread.start();
        }

        threads.forEach(t => t.join());
    "
}

############################################
# Update phase (SERVER-44991 trigger)
############################################
update_phase() {
    echo "==> Update phase — SERVER-44991"

    "$MONGO_BIN" --quiet --eval "
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
# Run
############################################
start_mongod
insert_phase
update_phase

echo "==> Repro complete"