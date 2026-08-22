# Restore Drill Guide

A backup you have never restored is just a hope, not a backup.

## Why Recovery Drills Matter

Backups can fail silently. A backup might report success but:

- The encryption key is wrong (you discover this at restore time — too late)
- The repository is subtly corrupt (a bit flipped in storage)
- The restore command has a bug or incompatibility with your tool version
- You forgot which snapshot to restore from
- The restored data is incomplete (an exclude pattern was too aggressive)
- The storage backend deleted old data (lifecycle policy, account closure)

The only way to know your backups work is to **actually restore from them**
and verify the result. A recovery drill automates this.

## How Drills Work

`mb backup drill` executes a complete recovery cycle:

```
1. Run a fresh backup        →  proves backup still works
2. Restore latest snapshot   →  proves restore works
3. Compare file count + size →  proves data is complete
4. Generate a report         →  documents the result
5. Clean up temp directory   →  no leftover artifacts
```

### The Comparison

The drill compares two metrics between the source (`/data/`) and the restored
copy:

- **File count** — the number of regular files. A mismatch means files were
  lost or extra files appeared.
- **Total size** — the sum of file sizes. A delta greater than 5% flags a
  failure (small deltas are expected due to filesystem metadata rounding).

If both match, the drill **PASSES**. If either mismatches, it **FAILS** with
a specific reason.

### The Report

Each drill writes a text report to `/var/lib/mb-backup/`:

```
==========================================
 mb-backup Recovery Drill Report
==========================================
Date       : 2026-01-01 05:00:12
Strategy   : restic-s3
Source     : /data
Target     : /tmp/mb-restore/drill-20260101-050012
Duration   : 47s

---- Metrics ----
Source files     : 12847
Source size      : 2.3 GB (2348291840 bytes)
Restored files   : 12847
Restored size    : 2.3 GB (2348291840 bytes)
Size delta       : 0%

---- Verdict ----
Result           : PASS

A backup you have never tested is just a hope, not a backup.
==========================================
```

## Running a Drill

```bash
# Run a drill with the active strategy
mb backup drill

# Run a drill with a specific strategy
mb backup drill --strategy restic-sftp

# Run a drill on a specific source directory
mb backup drill --source /data/my-app
```

## Scheduling Drills

The included cron template runs a drill monthly (1st of the month at 5 AM):

```bash
crontab /etc/mb-backup/backup-cron
```

Monthly is a good default. Run a drill more often if:

- You make frequent configuration changes
- You've changed your backup strategy or backend
- You've updated Restic/Kopia/Borgmatic to a new major version

## When a Drill Fails

A failed drill is **good news** — you found the problem before you needed the
backup. Investigate:

1. **Read the report** — it tells you whether it was file count, size, or a
   step failure (backup or restore didn't complete).
2. **Check the log** — `/var/log/mb-backup.log` has detailed output.
3. **Run restore manually** — `mb backup restore --latest --target /tmp/test`
   and inspect the restored data.
4. **Run verify** — `mb backup verify` checks repository integrity.
5. **Fix and re-run** — after fixing the issue, run `mb backup drill` again
   until it passes.

## Drill vs Verify

| | `mb backup verify` | `mb backup drill` |
|---|---|---|
| What it checks | Repository integrity (no corruption) | Full backup → restore → data comparison |
| Reads data? | Metadata only | Full data restore |
| Writes data? | No | Yes (temp directory, cleaned up) |
| Time | Seconds to minutes | Minutes to hours (depends on data size) |
| Frequency | Weekly | Monthly |

Run **verify** weekly (fast, catches corruption) and **drill** monthly
(slow, proves end-to-end recoverability).

## Restore Test Script (Checksum Verification)

In addition to `mb backup drill`, backup-kit includes a standalone
**restore test script** that performs a deeper integrity check using
SHA-256 checksums.

### `scripts/restore-test.sh`

Unlike `mb backup drill` (which runs a fresh backup and compares file count +
size), `restore-test.sh` restores an **existing** snapshot and compares
**checksums** of every file between the source and the restored copy. This
catches silent bit-rot or partial corruption that size-only checks would miss.

```bash
# Restore a random snapshot and verify all checksums (Restic)
scripts/restore-test.sh --backend restic --source /data

# Restore a random snapshot and verify all checksums (Kopia)
scripts/restore-test.sh --backend kopia --source /data

# Restore a specific snapshot
scripts/restore-test.sh --backend restic --snapshot abc12345 --source /data

# Keep the restored data for manual inspection
scripts/restore-test.sh --backend restic --keep --source /data

# For large datasets, sample 100 random files instead of checking all
scripts/restore-test.sh --backend restic --sample 100 --source /data

# Custom target and report paths
scripts/restore-test.sh --backend restic \
    --source /data \
    --target /tmp/my-restore \
    --report /var/lib/mb-backup/my-report.txt
```

### Options

| Option | Description | Default |
|---|---|---|
| `--backend restic\|kopia` | Backup backend (required) | — |
| `--snapshot auto\|<ID>` | Snapshot to restore | `auto` (random pick) |
| `--source PATH` | Source data to compare against | `/data` |
| `--target PATH` | Restore target directory | `/tmp/mb-restore-test-<ts>` |
| `--report PATH` | Report file path | `/var/lib/mb-backup/restore-test-<ts>.txt` |
| `--strategy NAME` | Strategy name for config lookup | auto-detected |
| `--keep` | Keep restored data after drill | cleaned up |
| `--sample N` | Verify N random files (0 = all) | `0` (all) |

### How It Works

```
1. Select snapshot    →  auto-pick a random snapshot, or use the one you specify
2. Restore            →  restore the snapshot to a temporary directory
3. Locate data        →  find the restored data root (handles path offsets)
4. Verify checksums   →  compare SHA-256 of every file (or a random sample)
5. Generate report    →  write a pass/fail report with mismatch details
```

### Interpreting the Report

- **PASS** — all file counts match and every checksum is identical.
- **WARN** — file counts match but extra files were found in the restore
  (usually harmless, but worth investigating).
- **FAIL** — files are missing or checksums don't match. The report lists
  up to 10 mismatched files with their source and restored checksums.

### Drill vs Restore Test

| | `mb backup drill` | `scripts/restore-test.sh` |
|---|---|---|
| What it checks | File count + total size | SHA-256 checksum of every file |
| Runs a backup first? | Yes (fresh backup) | No (uses existing snapshot) |
| Snapshot selection | Latest | Random (or specified) |
| Detects bit-rot? | No (size-only) | Yes (checksum comparison) |
| Speed | Slower (includes backup) | Faster (restore only) |
| Frequency | Monthly | Monthly (or after major changes) |

### Common Issues

**"No snapshots found in the repository"**
Run `mb backup run` to create a backup first, or check that your repository
credentials are correct.

**"Could not locate restored data under target"**
The script tries several path layouts to find the restored data. If your
backup tool uses a non-standard restore layout, use `--keep` to preserve the
restored data and inspect the directory structure manually.

**"Source directory does not exist"**
The `--source` path must point to the original data that was backed up.
The script compares files in the source against files in the restore.

**Checksum mismatches on a fresh restore**
This should never happen. If it does, your backup repository may be corrupt.
Run `mb backup verify` to check repository integrity, then investigate
storage backend health.
