# Advanced Backup Guide

This guide covers advanced backup scenarios beyond the standard file-level
backup: Docker volume backup with compression and encryption, Elasticsearch
index backup, and InfluxDB time-series backup. These scenarios require
special handling because the data lives inside Docker volumes or
specialized database engines that cannot be safely copied at the file level.

## Table of Contents

- [Docker Volume Backup](#docker-volume-backup)
- [Elasticsearch Backup](#elasticsearch-backup)
- [InfluxDB Backup](#influxdb-backup)
- [Encryption: age vs gpg](#encryption-age-vs-gpg)
- [Integration with db-backup.sh](#integration-with-db-backupsh)
- [3-2-1 Backup Rule in Advanced Scenarios](#3-2-1-backup-rule-in-advanced-scenarios)

---

## Docker Volume Backup

Docker named volumes store persistent data outside the container filesystem.
They cannot be copied with `cp` because they live in Docker's managed storage
area (`/var/lib/docker/volumes/`). The `scripts/volume-backup.sh` script
handles this by spinning up a temporary alpine container that mounts the
volume read-only and exports its contents as a compressed tar archive.

### Basic Usage

```bash
# Back up a single volume to /backup/
mb backup volume-backup --volume my-app-data

# Back up all volumes, excluding system volumes
mb backup volume-backup --all --exclude '*meta*' --exclude 'docker-_'

# Preview what would be backed up (no files written)
mb backup volume-backup --all --dry-run
```

### Compression Options

| Option | Flag | Extension | Best For |
|---|---|---|---|
| gzip | `--compress gzip` (default) | `.tar.gz` | General purpose, good ratio, universally available |
| zstd | `--compress zstd` | `.tar.zst` | Faster compression/decompression, good ratio |
| none | `--compress none` | `.tar` | Already-compressed data, or when Restic/Kopia handles compression |

### Encryption Options

Encrypt archives at backup time so the storage backend never sees plaintext:

```bash
# Encrypt with age (recommended — modern, simple, no key management complexity)
mb backup volume-backup --volume my-app-data \
    --encrypt age --age-recipient age1xxxx...

# Encrypt with gpg (use existing GPG key infrastructure)
mb backup volume-backup --volume my-app-data \
    --encrypt gpg --gpg-recipient admin@example.com
```

See [Encryption: age vs gpg](#encryption-age-vs-gpg) for a comparison.

### Direct Restic Streaming

Instead of writing archives to disk, stream them directly into a Restic
repository. This avoids intermediate storage and leverages Restic's
deduplication and encryption:

```bash
mb backup volume-backup --all --restic \
    --restic-repo s3:s3.amazonaws.com/my-bucket \
    --restic-password my-passphrase
```

Each volume is streamed as a separate stdin backup with a descriptive
filename (`volume-<name>-<timestamp>.tar.gz`).

### Reports

Each run produces TXT and JSON reports (default: `/var/lib/mb-backup/`):

- **TXT report** — human-readable table with volume name, status, size,
  duration, and archive filename.
- **JSON report** — machine-readable format for monitoring integration.

### Error Handling

The script handles these error conditions:

| Condition | Behavior |
|---|---|
| Volume does not exist | Records `FAIL` status, continues with other volumes |
| Insufficient disk space | Warns before starting (best-effort check) |
| Backup command fails | Records `FAIL` with exit code, keeps archives for inspection |
| Docker not installed | Exits with code 2 (prerequisite error) |

On success, temporary archive files are cleaned up automatically (unless
`--keep` is specified). On failure, archives are preserved for inspection.

---

## Elasticsearch Backup

Elasticsearch indices require special backup handling. A file-level copy
of ES data files will capture an inconsistent state. backup-kit provides
two backup methods via `lib/es-dump.sh`:

### Method Comparison

| Method | Tool | How It Works | Best For |
|---|---|---|---|
| **elasticdump** | `elasticdump` CLI | Exports each index as JSON (mapping + data documents) | Small to medium indices, portable exports, no ES config changes |
| **snapshot** | ES Snapshot/Restore API | Creates point-in-time snapshots in a registered repository | Large clusters, production environments, incremental backups |

### elasticdump Method

Exports each index as two JSON files: a mapping file (settings, analyzers)
and a data file (documents). No ES configuration changes are needed.

```bash
# Back up a specific index
lib/es-dump.sh --host http://localhost:9200 --index my-index

# Back up all indices
lib/es-dump.sh --host http://localhost:9200 --all-indices

# Auto-discover via Docker labels
lib/es-dump.sh --auto
```

**Pros:**
- No ES configuration changes needed
- Output is portable JSON — can be imported into any ES instance
- Works with any ES version

**Cons:**
- Slower for large indices (exports all documents)
- No incremental/differential backups
- Requires `elasticdump` installed (`npm install -g elasticdump`)

### Snapshot API Method

Uses Elasticsearch's built-in Snapshot/Restore API to create consistent
point-in-time snapshots. Requires a registered snapshot repository (shared
filesystem, S3, etc.).

```bash
# Register a filesystem repository first (one-time setup)
curl -X PUT "localhost:9200/_snapshot/my_backup" -H 'Content-Type: application/json' -d'
{
  "type": "fs",
  "settings": { "location": "/mnt/backups/my_backup" }
}'

# Back up using the snapshot method
lib/es-dump.sh --host http://localhost:9200 --all-indices \
    --method snapshot --snapshot-repo my_backup
```

**Pros:**
- Point-in-time consistent snapshots
- Supports incremental backups (only changed data is stored)
- Works at cluster level (all indices, or specific indices)
- Native ES feature — no external tools

**Cons:**
- Requires repository registration (one-time setup)
- Snapshot is stored in the repository, not as a portable file
- Repository backend must be accessible during restore

### Docker Auto-Discovery

Add the `backup.es-cluster` label to your ES containers:

```yaml
services:
  elasticsearch:
    image: elasticsearch:8
    labels:
      backup.es-cluster: my-cluster
      backup.es-port: 9200
      backup.es-method: elasticdump  # or snapshot
```

Then run `lib/es-dump.sh --auto` to discover and back up all labeled
ES instances.

---

## InfluxDB Backup

InfluxDB is a time-series database that needs specialized backup handling.
The `lib/influxdb-dump.sh` library supports both InfluxDB 1.x and 2.x using
the native `influx backup` / `influxd backup` commands.

### InfluxDB 1.x

Uses `influxd backup` (or `influx backup` on some builds) with the
`-database` flag for per-database backups, or without it for full backups.

```bash
# Back up a specific database
lib/influxdb-dump.sh --host http://localhost:8086 \
    --version-major 1 --database mydb

# Full backup (all databases)
lib/influxdb-dump.sh --host http://localhost:8086 \
    --version-major 1 --all

# With authentication
lib/influxdb-dump.sh --host http://localhost:8086 \
    --version-major 1 --database mydb \
    --username admin --password secret
```

### InfluxDB 2.x

Uses `influx backup` with `--token` and `--org` for authentication, and
`--bucket` for per-bucket backups.

```bash
# Back up a specific bucket
lib/influxdb-dump.sh --host http://localhost:8086 \
    --version-major 2 --database my-bucket \
    --token my-api-token --org my-org

# Full backup (all buckets)
lib/influxdb-dump.sh --host http://localhost:8086 \
    --version-major 2 --all \
    --token my-api-token --org my-org
```

### Version Auto-Detection

If `--version-major` is not specified, the script queries the `/health`
endpoint to detect the version automatically. InfluxDB 2.x returns a JSON
response with a `"version"` field; 1.x returns a 204 status from `/ping`.

### Docker Auto-Discovery

Add the `backup.influxdb` label to your InfluxDB containers:

```yaml
services:
  influxdb:
    image: influxdb:2
    labels:
      backup.influxdb: "2"           # major version: "1" or "2"
      backup.influxdb-port: 8086
      backup.influxdb-org: my-org    # 2.x only
```

Then run `lib/influxdb-dump.sh --auto` to discover and back up all labeled
InfluxDB instances. For 2.x, the API token should be provided via the
`INFLUX_TOKEN` environment variable (not in labels, for security).

---

## Encryption: age vs gpg

Both `age` and `gpg` can encrypt volume backup archives. Here's how to
choose:

| Aspect | age | gpg |
|---|---|---|
| **Design philosophy** | Simple, modern, no configuration | Feature-rich, complex, key management |
| **Key management** | Recipient strings (public keys) | GPG keyring, web of trust, key servers |
| **Ease of use** | Very simple — one recipient string | Steeper learning curve |
| **Availability** | Newer, may need manual install | Pre-installed on most Linux systems |
| **Auditability** | Small codebase, easy to audit | Large codebase, long history |
| **Best for** | Automated backup encryption, CI/CD | Organizations with existing GPG infrastructure |

### Recommendation

**Use `age` for new backup setups.** It's simpler, has a smaller attack
surface, and is designed specifically for encryption (not communication).
Use `gpg` only if you already have a GPG key infrastructure in place.

### Setting up age

```bash
# Install age
# macOS: brew install age
# Linux: apt-get install age  (or build from source)

# Generate a key pair
age-keygen -o age-key.txt

# The public key (recipient) is printed to stdout
# Use it with volume-backup:
mb backup volume-backup --volume my-data \
    --encrypt age --age-recipient age1xxxx...
```

---

## Integration with db-backup.sh

The advanced backup scripts are designed to work together with
`db-backup.sh` in a coordinated pipeline. The recommended workflow is:

```
1. db-backup.sh    →  Dump databases (Postgres, MySQL, Redis, Mongo)
2. es-dump.sh      →  Export Elasticsearch indices
3. influxdb-dump.sh →  Back up InfluxDB databases/buckets
4. volume-backup.sh →  Back up Docker volumes (including dump directories)
5. restic backup    →  Capture everything in an encrypted snapshot
```

### Example Pipeline

```bash
#!/bin/bash
set -euo pipefail

# 1. Dump databases to /backup/db-dumps-<ts>/
mb backup db-backup --auto --keep

# 2. Export Elasticsearch indices to /backup/es-dumps-<ts>/
lib/es-dump.sh --auto --output-dir /backup/es-dumps-$(date +%Y%m%d-%H%M%S)

# 3. Back up InfluxDB to /backup/influxdb-backups-<ts>/
lib/influxdb-dump.sh --auto --output-dir /backup/influxdb-backups-$(date +%Y%m%d-%H%M%S)

# 4. Back up Docker volumes (including the dump directories)
mb backup volume-backup --all --keep \
    --output-dir /backup/volume-backups-$(date +%Y%m%d-%H%M%S)

# 5. Run the main backup (captures /data/ and all dump directories)
mb backup run

# 6. Clean up temporary dump directories
rm -rf /backup/db-dumps-* /backup/es-dumps-* /backup/influxdb-backups-* /backup/volume-backups-*
```

### Why This Order Matters

1. **Database dumps first** — ensures consistent, point-in-time database
   images before anything else runs.
2. **ES and InfluxDB dumps** — these are also database engines that need
   consistent exports.
3. **Volume backup** — captures any data stored in volumes, including the
   dump directories from steps 1-3 if they're on volumes.
4. **Main backup** — the Restic/Kopia snapshot captures everything: the
   original data, the database dumps, the ES exports, and the InfluxDB
   backups.

This ordering ensures that the final snapshot contains a complete,
consistent, recoverable picture of your entire system.

---

## 3-2-1 Backup Rule in Advanced Scenarios

The 3-2-1 rule (3 copies, 2 different media, 1 off-site) applies to
advanced backup scenarios with some specific considerations:

### 3 Copies

| Copy | What | Where |
|---|---|---|
| Primary | Live data | Docker volumes, database files |
| Copy 1 | Dump files + volume archives | Local `/backup/` directory |
| Copy 2 | Restic/Kopia snapshot | Remote storage (S3, SFTP) |

### 2 Different Media

- **Media 1**: Local disk (dump files, volume archives)
- **Media 2**: Cloud storage (Restic/Kopia repository on S3/Wasabi/B2)
  or SFTP to another VPS

### 1 Off-site

The Restic/Kopia repository on cloud storage (or a remote VPS via SFTP)
satisfies the off-site requirement. The `mb backup compliance` command
can audit your setup against this rule.

### Advanced Considerations

1. **Database dumps are a separate copy** — even if the main backup fails,
   the dump files in `/backup/` provide a recovery path. Use `--keep` to
   preserve them.

2. **Volume archives can be encrypted separately** — even if your Restic
   repository is compromised, volume archives encrypted with `age` or
   `gpg` remain protected by a separate encryption layer.

3. **ES snapshot repositories can be on different backends** — register
   multiple repositories (e.g., one on local NFS, one on S3) for
   additional redundancy.

4. **InfluxDB backups are full copies** — unlike incremental snapshots,
   InfluxDB backups are complete copies, making them easy to restore but
   larger in size. Schedule them less frequently if storage is a concern.

5. **Test restores of all data types** — run `mb backup drill` regularly,
   and periodically test restoring a database dump, an ES index, an
   InfluxDB backup, and a volume archive to ensure all recovery paths work.

---

## See Also

- [Database Backup Guide](database-backup.md) — PostgreSQL, MySQL, Redis, MongoDB dumps
- [Docker Volume Backup](docker-volume-backup.md) — Basic volume export/restore
- [Backup Strategy Guide](backup-strategy-guide.md) — Choosing Restic vs Kopia vs Borgmatic
- [S3 Backend Comparison](backends-comparison.md) — Wasabi vs B2 vs MinIO vs AWS S3
- [Restore Drill Guide](restore-drill.md) — Testing your backups work
