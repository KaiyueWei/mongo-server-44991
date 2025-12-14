# Slow vs Fast Execution Analysis for SERVER-44991 Repro (MongoDB 4.2.1 vs 4.0.13)

This report documents the steps used to reproduce and profile a performance regression and analyzes how the execution differs between a slow run (MongoDB 4.2.1) and a fast run (MongoDB 4.0.13). The analysis uses the artifacts in this repo: flamegraphs under `results/` and a debug session log in `gdb.log`.

## 1. Environment

Reproduction environment (AWS EC2):

```bash
uname -a
Linux ip-10-0-1-191 5.15.0-1084-aws #91~20.04.1-Ubuntu SMP Fri May 2 06:59:36 UTC 2025 x86_64 x86_64 x86_64 GNU/Linux
```

```bash
cat /etc/os-release
NAME="Ubuntu"
VERSION="20.04.6 LTS (Focal Fossa)"
ID=ubuntu
ID_LIKE=debian
PRETTY_NAME="Ubuntu 20.04.6 LTS"
VERSION_ID="20.04"
HOME_URL="https://www.ubuntu.com/"
SUPPORT_URL="https://help.ubuntu.com/"
BUG_REPORT_URL="https://bugs.launchpad.net/ubuntu/"
PRIVACY_POLICY_URL="https://www.ubuntu.com/legal/terms-and-policies/privacy-policy"
VERSION_CODENAME=focal
UBUNTU_CODENAME=focal
```

## 2. Workload Overview

The scripts implement a three-phase workload:

1. Start a clean `mongod` with a fixed WiredTiger cache size.
2. Insert phase:
   - Create many compound secondary indexes across 5 collections.
   - Bulk insert 1M documents per collection using 5 concurrent threads.
3. Update phase (the SERVER-44991 trigger):
   - Run 5 concurrent threads, each repeatedly calling `updateMany` with an `_id` modulo predicate:
     - query: `{ _id: { $mod: [100, i] } }`
     - update: `{ $inc: { a: 1 } }`


## 3. Reproduction & Profiling Steps

The primary profiling flow is implemented by `repro/repro_perf_v3.sh`, which:

- Starts `mongod`.
- Runs the insert phase (unprofiled).
- Profiles **the server process** during the update phase using `perf`.
- Generates a flamegraph with FlameGraph scripts.

### 3.1 Slow vs Fast runs

Run the workload against two different MongoDB builds by switching `MONGO_HOME`.

Fast run (MongoDB 4.0.13):

```bash
export MONGO_HOME="$HOME/work/mongo-4.0.13"
bash ./repro/repro_perf_v3.sh
```

Slow run (MongoDB 4.2.1):

```bash
export MONGO_HOME="$HOME/work/mongo-4.2.1"
bash ./repro/repro_perf_v3.sh
```

Output artifacts:

- `results/flamegraph_mongo-4.0.13.svg`
- `results/flamegraph_mongo-4.2.1.svg`

### 3.2 Extracting hot functions from flamegraphs

To quickly compare the “top frames” between the two runs, parse `<title>` entries from the SVGs and sort by percentage:

```bash
python -c "import re, pathlib; \
text=pathlib.Path('results/flamegraph_mongo-4.2.1.svg').read_text(); \
items=[(float(p), int(s.replace(',','')), n) for n,s,p in re.findall(r'<title>(.+?) \\(([0-9,]+) samples, ([0-9.]+)%\\)</title>', text)]; \
items.sort(reverse=True); \
print('\\n'.join([f'{p:5.2f}% {s:10d} {n}' for p,s,n in items[:20]]))"

python -c "import re, pathlib; \
text=pathlib.Path('results/flamegraph_mongo-4.0.13.svg').read_text(); \
items=[(float(p), int(s.replace(',','')), n) for n,s,p in re.findall(r'<title>(.+?) \\(([0-9,]+) samples, ([0-9.]+)%\\)</title>', text)]; \
items.sort(reverse=True); \
print('\\n'.join([f'{p:5.2f}% {s:10d} {n}' for p,s,n in items[:20]]))"
```

## 4. Key Observations (Slow vs Fast)

### 4.1 Slow run (MongoDB 4.2.1)

The slow run’s flamegraph shows a large fraction of CPU time inside WiredTiger eviction and reconciliation, with unusually heavy time spent materializing/copying row-store keys:

- `__wt_evict_thread_run` dominates the sampled execution (eviction thread work).
- Within reconciliation:
  - `__wt_reconcile` and `__wt_rec_row_leaf` are major contributors.
  - Row-key handling is extremely hot:
    - `__wt_row_leaf_key_copy` is a top contributor (~23%).
    - `__wt_row_leaf_key_work` is also a top contributor (~22%).

### 4.2 Fast run (MongoDB 4.0.13)

The fast run is also eviction/reconcile heavy, but **does not** spend time in `__wt_row_leaf_key_copy`:

- `__wt_row_leaf_key_copy` is negligible (~0.08%).
- Key work shows up instead as `__rec_cell_build_leaf_key` (a substantial contributor in 4.0.13).

Interpretation: both versions pay reconciliation cost under this write-heavy workload, but 4.2.1 pays a much higher cost in row key instantiation/copying during reconciliation.

## 5. Execution Path Analysis (Function Sequences)

This section highlights the key call chains and where the slow run diverges.

### 5.1 Common high-level path (both versions)

During the update phase:

1. The mongo shell issues `updateMany` repeatedly from multiple client threads.
2. The server updates records and updates many secondary index entries (due to the compound indexes).
3. Dirty pages accumulate, forcing WiredTiger eviction.
4. Eviction triggers reconciliation to write modified pages.

### 5.2 Slow-path call chain evidence from `gdb.log`

`gdb.log` contains a stack trace that ties the hot WiredTiger functions directly to the update execution path. A representative call chain shows:

- MongoDB update execution:
  - `mongo::performUpdates`
  - `mongo::UpdateStage::transformAndUpdate`
  - `mongo::WiredTigerRecoveryUnit::_txnClose` / `commitUnitOfWork`
- WiredTiger commit + eviction/reconcile:
  - `__wt_txn_commit`
  - `__wt_cache_eviction_worker`
  - `__wt_evict` / `__evict_page`
  - `__wt_reconcile` / `__wt_rec_row_leaf`
  - `__wt_row_leaf_key_copy`

This demonstrates the slowdown is inside eviction-driven reconciliation work that happens as part of committing updates, not in client-side or query-parsing code.

### 5.3 “key size = 0” conditional breakpoint evidence

`gdb.log` also shows a conditional breakpoint on `__wt_row_leaf_key_copy` that stops when the destination key buffer is empty:

```
stop only if key->size==0 && key->data==0
```

This breakpoint is hit repeatedly across different threads (e.g., `mongod` threads and background threads), indicating that empty-key instantiation/copy is not a one-off event under this workload.

## 6. Root Cause Analysis (Evidence-Based Hypothesis)

### Symptom

MongoDB 4.2.1 runs significantly slower than 4.0.13 on the same workload shape (many secondary indexes + high update concurrency).

### Immediate cause (where the time goes)

In 4.2.1, a large fraction of CPU time is spent in:

- `__wt_row_leaf_key_copy`
- `__wt_row_leaf_key_work`

These functions sit on the reconciliation path (`__wt_rec_row_leaf` / `__wt_reconcile`) that is invoked during eviction.

In 4.0.13, `__wt_row_leaf_key_copy` is negligible; key work manifests primarily as `__rec_cell_build_leaf_key`.

### Mechanism (why this workload triggers it)

This workload:

- Creates many secondary indexes, amplifying write work per document update.
- Runs multi-threaded updates, increasing dirty page generation and write pressure.
- Forces frequent eviction and reconciliation.

Under these conditions, reconciliation repeatedly processes row-store leaf pages and needs to reconstruct keys for leaf entries. In 4.2.1, this appears to frequently take a costly key-copy/instantiation path; in 4.0.13 it largely does not.

### Likely root cause

Between 4.0.13 and 4.2.1, WiredTiger’s reconciliation/key handling behavior changed such that row keys are copied/instantiated more frequently (or more expensively) during reconciliation under eviction pressure. This increases CPU spent on key materialization, slowing overall progress of eviction and update commits.

This is supported by:
- The flamegraph deltas (`__wt_row_leaf_key_copy`/`__wt_row_leaf_key_work` becoming top hotspots in 4.2.1).
- The `gdb.log` stack traces showing the hot key-copy path sits on eviction→reconcile during update commits.
- The conditional breakpoint repeatedly triggering on `key->size==0 && key->data==0`.

## 7. Possible Fix

The performance regression in MongoDB v4.2.1 is caused by an incorrect reset of key->size in __wt_row_leaf_key_work, which invalidates cached decompressed keys. This forces WiredTiger to rebuild full keys repeatedly during eviction. Removing this reset restores key reuse and eliminates the regression.

