# adjust these for your environment
db=/ssd/db

function start {
    rm -rf $db
    mkdir -p $db
    killall -9 -w mongod mongo
    mongod --dbpath $db --logpath $db.log --wiredTigerCacheSizeGB 10 --fork
    sleep 3
}

function insert {

    mongo --eval '
    
        // adjust this
        load("/home/bdlucas/mongodb/git/mongo/jstests/libs/parallelTester.js")

        for (var b = 0; b < 10; b++) {
            spec = {x: 1, a: 1, _id: 1}
            spec["b"+b] = 1
            db.c0.createIndex(spec, {unique: false})
            db.c1.createIndex(spec, {unique: false})
            db.c2.createIndex(spec, {unique: false})
            db.c3.createIndex(spec, {unique: false})
            db.c4.createIndex(spec, {unique: false})
        }
    
        nthreads = 5
        threads = []
    
        for (var t = 0; t < nthreads; t++) {
    
            thread = new ScopedThread(function(t) {
    
                size = 20
                count = 1*1000*1000;
                every = 1000
                x = "x".repeat(size)
    
                c = db["c"+t]
    
                for (var i=0; i<count; i++) {
                    if (i % every == 0) {
                        if (i > 0)
                            c.insertMany(many)
                        many = []
                    }
                    doc = {_id:i, x:x, b0:0, b1:0, b2:0, b3:0, b4:0, b5:0, b6:0, b7:0, b8:0, b9:0, a: 0}
                    many.push(doc)
                    if (i%10000==0) print(t, i)
                }
    
            }, t)
            threads.push(thread)
            thread.start()
        }
        for (var t = 0; t < nthreads; t++)
            threads[t].join()
    '
}

function update {

    mongo --eval '

        // adjust this
        load("/home/bdlucas/mongodb/git/mongo/jstests/libs/parallelTester.js")
    
        nthreads = 5
        threads = []
    
        for (var t = 0; t < nthreads; t++) {
            thread = new ScopedThread(function(t) {
                mod = 100
                c = db["c"+t]
                for (var i = 0; i < 20; i++)
                    c.updateMany({_id: {$mod: [mod, i%mod]}}, {$inc: {a: 1}})
                
            }, t)
            threads.push(thread)
            thread.start()
        }
        for (var t = 0; t < nthreads; t++)
            threads[t].join()

    '
}

start
insert
update


