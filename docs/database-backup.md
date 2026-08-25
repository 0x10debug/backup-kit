# Database-Aware Backup Guide

Databases need special handling during backup. A file-level copy of live
database files can capture an inconsistent state — a half-written transaction,
a torn page, or an index mid-rebuild. The solution is to run a **consistent
dump** before the backup, so the snapshot contains a clean, recoverable
database image.

backup-kit's `db-backup` command automates this for four database engines:

| Engine | Dump method | Output format |
|---|---|---|
| PostgreSQL | `pg_dump --format=custom` | Compressed custom format (`.dump`) |
| MySQL / MariaDB | `mysqldump --single-transaction --routines --triggers` | SQL text (`.sql`) |
| Redis | `redis-cli BGSAVE` + wait + copy RDB | Binary RDB snapshot (`.rdb`) |
| MongoDB | `mongodump --archive --gzip` | Compressed archive (`.archive.gz`) |

## How It Works

```
1. Discover targets   →  scan Docker labels, or use manual --type/--host
2. Run dumps          →  pg_dump / mysqldump / redis-cli / mongodump
3. Write report       →  TXT + JSON, with size, duration, and status per DB
4. Clean up           →  remove dump files (unless --keep or a dump failed)
```

The dump files are written to a temporary directory (default: `/backup/db-dumps-<timestamp>/`).
This directory should be included in your Restic/Kopia backup paths so the
dumps are captured in the next snapshot.

### Integration with Restic/Kopia

The typical workflow is:

```bash
# 1. Dump databases to /backup/db-dumps-<ts>/
mb backup db-backup --auto

# 2. Back up /data/ AND the dump directory together
restic backup /data /backup/db-dumps-*
```

Or in a single cron entry (see `cron/db-backup-cron.example`):

```bash
0 3 * * * /opt/mb-backup/mb backup db-backup --auto --keep && \
           /opt/mb-backup/mb backup run && \
           rm -rf /backup/db-dumps-*
```

The `--keep` flag prevents cleanup so the dumps survive until the backup
command picks them up. After the backup completes, the dumps are removed.

## Auto-Discovery (Docker Labels)

The easiest way to use `db-backup` is with Docker label-based auto-discovery.
Add a label to your database containers in `compose.yml`:

```yaml
services:
  postgres:
    image: postgres:16
    labels:
      backup.db-type: postgres
      backup.db-name: myapp
      backup.db-user: postgres
    # ...

  redis:
    image: redis:7
    labels:
      backup.db-type: redis
    # ...

  mongo:
    image: mongo:7
    labels:
      backup.db-type: mongo
      backup.db-name: myapp
    # ...
```

Then run:

```bash
mb backup db-backup --auto
```

The script scans all running containers for the `backup.db-type` label and
dumps each one. Additional labels refine the connection:

| Label | Description | Used by |
|---|---|---|
| `backup.db-type` | Database type: `postgres`, `mysql`, `redis`, `mongo` | All |
| `backup.db-name` | Database name | postgres, mysql, mongo |
| `backup.db-user` | Database user | postgres, mysql, mongo |
| `backup.db-port` | Override the default port | All |

For auto-discovered containers, the dump command is executed via
`docker exec` inside the container, so the database client tools
(`pg_dump`, `mysqldump`, `redis-cli`, `mongodump`) must be installed
inside the container image. Most official database images include these
tools by default.

## Manual Mode

If your database is not in Docker, or you want to dump a specific instance:

```bash
# PostgreSQL
mb backup db-backup --type postgres --host db.example.com \
    --user postgres --password secret --db myapp

# MySQL/MariaDB
mb backup db-backup --type mysql --host db.example.com \
    --user root --password secret --db myapp

# Redis
mb backup db-backup --type redis --host cache.example.com --password secret

# MongoDB
mb backup db-backup --type mongo --host mongo.example.com \
    --user admin --password secret --db myapp
```

### Environment Variables

Instead of passing `--password` on the command line (which exposes it in
process listings), you can use environment variables:

| Variable | Used by | Description |
|---|---|---|
| `PGPASSWORD` | PostgreSQL | Set automatically from `--password` |
| `MYSQL_PWD` | MySQL/MariaDB | MySQL reads this env var |
| `MONGO_PASSWORD` | MongoDB | Set via `--password` |

For auto-discovered Docker containers, passwords are read from environment
variables inside the container (e.g., `POSTGRES_PASSWORD`, `MYSQL_ROOT_PASSWORD`).
The dump tools inside the container use these automatically.

## Dry-Run Mode

Preview which databases would be backed up without writing any dumps:

```bash
mb backup db-backup --auto --dry-run
```

Output:

```
==> Database-aware backup (pre-backup dumps)
[2026-01-01 03:00:00] INFO Mode     : auto
[2026-01-01 03:00:00] INFO Dry-run  : true

==> Step 1/3 — Discovering database targets
[2026-01-01 03:00:00] INFO Discovered 2 database(s) via Docker labels.

==> Step 2/3 — Running database dumps
[2026-01-01 03:00:00] INFO DRY-RUN mode — no dumps will be written.
[2026-01-01 03:00:00] INFO [dry-run] Would dump: postgres [container: myapp-postgres] → postgres-myapp-postgres-5432-myapp.dump
[2026-01-01 03:00:00] INFO [dry-run] Would dump: redis [container: myapp-redis] → redis-myapp-redis-6379-all.rdb
```

## Reports

Each run writes two report files:

- **TXT report** — human-readable summary with a table of all databases,
  their dump sizes, durations, and status. Default location:
  `/var/lib/mb-backup/db-backup-<timestamp>.txt`

- **JSON report** — machine-readable format for monitoring integration.
  Default location: `/var/lib/mb-backup/db-backup-<timestamp>.json`

### JSON Report Format

```json
{
  "tool": "backup-kit db-backup",
  "version": "1.0.0",
  "timestamp": "2026-01-01T03:00:00Z",
  "mode": "auto",
  "dry_run": false,
  "dump_dir": "/backup/db-dumps-20260101-030000",
  "summary": {
    "total": 2,
    "succeeded": 2,
    "failed": 0
  },
  "databases": [
    {
      "type": "postgres",
      "host": "myapp-postgres",
      "port": "5432",
      "database": "myapp",
      "container": "myapp-postgres",
      "status": "OK",
      "size_bytes": 45678901,
      "duration_s": 12,
      "dump_file": "/backup/db-dumps-20260101-030000/postgres-myapp-postgres-5432-myapp.dump",
      "error": ""
    }
  ],
  "overall": "PASS"
}
```

## Error Handling

If any dump fails, `db-backup`:

1. Records the failure in the report (status `FAIL` with error message)
2. Logs the failure to `/var/log/mb-backup.log`
3. Keeps the dump directory for inspection (does not clean up on failure)
4. Exits with a non-zero code (1)

This allows cron jobs and CI pipelines to detect failures and trigger
alerts. The non-zero exit code also prevents a subsequent `mb backup run`
from proceeding if you chain the commands with `&&`.

## Scheduling

See `cron/db-backup-cron.example` for a ready-to-use cron template that
runs database dumps before the daily backup:

```bash
# Install the combined schedule
crontab /etc/mb-backup/db-backup-cron
```

The template runs `db-backup --auto --keep` at 2:55 AM (5 minutes before
the daily backup at 3:00 AM), so the dumps are ready when the backup
starts. The `--keep` flag ensures the dumps survive until the backup
captures them.

## Options Reference

| Option | Description | Default |
|---|---|---|
| `--auto` | Auto-discover databases via Docker labels | — |
| `--type TYPE` | Database type (manual mode) | — |
| `--host HOST` | Database host (manual mode) | — |
| `--port PORT` | Database port | per-type default |
| `--user USER` | Database user | — |
| `--password PWD` | Database password | — |
| `--db NAME` | Database name (ignored for Redis) | — |
| `--container NAME` | Docker container to exec into | — |
| `--dump-dir PATH` | Directory for dump files | `/backup/db-dumps-<ts>` |
| `--report PATH` | TXT report path | `/var/lib/mb-backup/db-backup-<ts>.txt` |
| `--json-report PATH` | JSON report path | alongside TXT report |
| `--keep` | Keep dump files after completion | cleaned up on success |
| `--dry-run` | Preview without writing dumps | — |

## Restore from Dumps

The dump files are standard database backup formats. Restore them with
the native tools:

```bash
# PostgreSQL (custom format)
pg_restore --host db.example.com --username postgres \
    --dbname myapp --clean postgres-myapp-5432-myapp.dump

# MySQL/MariaDB (SQL text)
mysql --host db.example.com --user root -p myapp \
    < mysql-myapp-3306-myapp.sql

# Redis (stop Redis, replace RDB, start Redis)
redis-cli SHUTDOWN
cp redis-myapp-6379-all.rdb /var/lib/redis/dump.rdb
redis-server --daemonize yes

# MongoDB (gzip archive)
mongorestore --host mongo.example.com --gzip --archive=mongo-myapp-27017-myapp.archive.gz
```

## Common Issues

**"No Docker containers with label 'backup.db-type' found"**
Add the `backup.db-type` label to your database containers in `compose.yml`,
then restart the containers.

**"pg_dump: command not found" (inside container)**
The database client tools must be installed inside the container. Most
official images (postgres, mysql, redis, mongo) include them. If you're
using a minimal image, install the client package or use manual mode
with a host that has the tools.

**"Dump file is empty"**
This usually means the connection failed silently. Check the database
credentials, network connectivity, and whether the database name is correct.

**Redis BGSAVE timeout**
If Redis is busy or the dataset is very large, BGSAVE may take longer than
60 seconds. The script copies the current RDB file anyway and warns. For
very large Redis instances, consider increasing the timeout or using
`--keep` to inspect the RDB file manually.
