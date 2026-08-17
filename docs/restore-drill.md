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
