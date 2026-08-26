# VPS Backup Made Simple — Encrypted, Automated, Tested Recovery

Protect your self-hosted data with encrypted, automated backups designed for VPS and Docker. Pre-configured strategies for Restic and Kopia handle encryption, retention, and cleanup—just add your storage backend. Includes Docker volume backup scripts, one-command restore, and automated recovery drills that verify your backups actually work. Because a backup you've never tested is just a hope, not a backup.

> **Already running apps on your VPS?** This is the safety net. Deploy your services with [compose-recipes](https://github.com/0x10debug/compose-recipes), then set up backup-kit to protect `/data/` — all your app data, encrypted, off-site, and tested.

## Why This Exists

Restic, Kopia, and Borgmatic are excellent backup **tools** — but they're not **strategies**. They give you the engine but not the route. You still have to decide:

1. **Which tool** fits your setup (Restic vs Kopia vs Borgmatic)?
2. **Which backend** (S3-compatible cloud vs SFTP to another VPS)?
3. **What retention policy** (how many daily, weekly, monthly snapshots)?
4. **How to back up Docker volumes** (you can't just `cp` them)?
5. **How to prove your backups work** (restore drills)?

backup-kit answers all five with pre-configured strategy templates. Pick a strategy, fill in your storage credentials, and you have a production-ready backup system with encryption, retention, automated cleanup, and recovery drills.

## Features

- **Encrypted by default** — AES-256 encryption (Restic) or client-side encryption (Kopia/Borg); your data is unreadable on the storage backend
- **Pre-configured strategies** — Restic + S3, Restic + SFTP, Kopia + S3, and Borgmatic; retention policies already set
- **Automated retention** — `forget --prune` runs after every backup; old snapshots are cleaned automatically
- **Docker volume backup** — export any named volume as a tar.gz via a temporary alpine container, or stream directly to Restic
- **Compose project backup** — back up every volume in a compose project plus its `compose.yml` and `.env`
- **Recovery drills** — `mb backup drill` runs a full backup → restore → verify cycle and writes a pass/fail report
- **Checksum verification** — `mb backup restore-test` restores a random snapshot and compares SHA-256 checksums to catch silent bit-rot
- **3-2-1 compliance check** — `mb backup compliance` audits your backup configuration against the 3-2-1 rule (3 copies, 2 media, 1 offline)
- **Database-aware backup** — `mb backup db-backup` dumps PostgreSQL, MySQL/MariaDB, Redis, and MongoDB before backup; auto-discovers databases via Docker labels
- **S3 backend templates** — ready-to-fill configs for Wasabi, Backblaze B2, and self-hosted MinIO, plus a [comparison guide](docs/backends-comparison.md)
- **Backend migration** — `mb backup backend-migrate` copies snapshots between S3 backends (AWS S3 → Wasabi → MinIO) via `restic copy`, with `--dry-run` preview
- **VPS migration** — `mb backup export` packages `/data/`, compose configs, and Docker volumes for moving to a new server
- **Cron templates** — daily backup, weekly verify, monthly drill, ready to install

## Available Strategies

| Strategy | Tool | Backend | Best For |
|---|---|---|---|
| [restic-s3](strategies/restic-s3/) | Restic | S3-compatible (AWS S3, Wasabi, B2, MinIO, R2) | Default choice — fast, deduplicated, encrypted |
| [restic-sftp](strategies/restic-sftp/) | Restic | SFTP (another VPS) | No cloud account — use a second VPS as storage |
| [kopia-s3](strategies/kopia-s3/) | Kopia | S3-compatible | Want a Web GUI to browse and restore snapshots |
| [borgmatic](strategies/borgmatic/) | Borgmatic (Borg) | SSH / SFTP | Prefer YAML declarative config with Borg compression |

All strategies default to **7 daily + 4 weekly + 6 monthly** retention and back up `/data/` by default.

### S3 Backend Templates

The `restic-s3` strategy ships with ready-to-fill templates for common S3-compatible backends. Copy the one you want to `.env` and fill in credentials:

| Template | Backend | Notes |
|---|---|---|
| [wasabi.env.example](strategies/restic-s3/wasabi.env.example) | Wasabi | No egress fees; 90-day minimum storage duration |
| [b2.env.example](strategies/restic-s3/b2.env.example) | Backblaze B2 | Native `b2:` mode (recommended) or S3-compatible mode |
| [minio.env.example](strategies/restic-s3/minio.env.example) | MinIO (self-hosted) | Includes a [docker-compose](strategies/restic-s3/minio-docker-compose.yml) server template |
| [.env.example](strategies/restic-s3/.env.example) | AWS S3 (default) | The base template — works with any S3-compatible storage |

See the [S3 backend comparison](docs/backends-comparison.md) for pricing, performance, and migration guidance.

## Quick Start

```bash
# 1. Harden your VPS and install Docker (if not done)
# → https://github.com/0x10debug/vps-bootstrap

# 2. Clone this repo
git clone https://github.com/0x10debug/backup-kit.git
cd backup-kit

# 3. Initialize a backup strategy (interactive)
./mb backup init
# → choose restic-s3, enter S3 credentials, set encryption password

# 4. Run your first backup
./mb backup run

# 5. Verify the backup is intact
./mb backup verify

# 6. Test that you can actually restore (recovery drill)
./mb backup drill

# 7. Install the cron schedule (daily backup, weekly verify, monthly drill)
#    mb backup init offers to do this automatically
crontab /etc/mb-backup/backup-cron
```

## Usage

```bash
mb backup init                       # Interactive strategy setup
mb backup init --config .env         # Declarative setup from a config file
mb backup run                        # Execute a backup now
mb backup status                     # Last backup time, snapshot count, repo size
mb backup verify                     # Verify backup integrity
mb backup restore --snapshot ID      # Restore from a specific snapshot
mb backup restore --latest           # Restore from the latest snapshot
mb backup drill                      # Run a full recovery drill
mb backup restore-test               # Restore a snapshot and verify checksums
mb backup compliance                 # Check 3-2-1 backup compliance
mb backup db-backup --auto           # Dump databases before backup (Docker auto-discovery)
mb backup backend-migrate --from-env wasabi.env --to-env minio.env --dry-run
                                     # Preview migrating snapshots between backends
mb backup cleanup                    # Apply retention policy (forget + prune)
mb backup export                     # Export all data for VPS migration
mb backup list                       # List all snapshots
mb backup help                       # Show help
```

### Declarative Setup

Create a `.env` file with your strategy and credentials:

```bash
MB_STRATEGY=restic-s3
RESTIC_REPOSITORY=s3:s3.amazonaws.com/my-backup-bucket
AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE
AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
RESTIC_PASSWORD=your-encryption-passphrase
BACKUP_PATHS=/data
RETENTION_DAILY=7
RETENTION_WEEKLY=4
RETENTION_MONTHLY=6
```

Then initialize non-interactively:

```bash
mb backup init --config .env
```

### Backing Up Docker Volumes

```bash
# Export a single volume to /backup/
docker/volume-backup.sh my-app-data /backup/

# Stream a volume directly into Restic (no intermediate file)
docker/volume-backup.sh my-app-data --restic

# Restore a volume from an archive
docker/volume-restore.sh my-app-data /backup/my-app-data-20260101-030000.tar.gz

# Back up an entire compose project (all volumes + compose.yml + .env)
docker/compose-backup.sh /opt/my-app /backup/my-app-$(date +%Y%m%d)
```

## FAQ

### How to backup Docker volumes on VPS?

Docker volumes can't be copied directly with `cp` because they live in Docker's managed storage. Use `docker/volume-backup.sh <volume-name>` — it spins up a temporary alpine container that mounts the volume read-only and exports its contents as a compressed tar.gz. To restore, use `docker/volume-restore.sh <volume-name> <archive.tar.gz>`, which imports the archive back into the volume. See the [Docker volume backup guide](docs/docker-volume-backup.md).

### How to set up encrypted backup with Restic?

Run `mb backup init` and choose `restic-s3` (or `restic-sftp` for SFTP). Enter your storage credentials and an encryption passphrase. Restic encrypts all data and metadata with AES-256 before it leaves your VPS — the storage backend only sees ciphertext. Your passphrase is never sent anywhere. Backups run via `mb backup run` and old snapshots are pruned automatically per the retention policy.

### How to automate VPS backup to S3?

After `mb backup init`, accept the cron install prompt (or run `crontab /etc/mb-backup/backup-cron`). This schedules a daily backup at 3 AM, a weekly integrity verification on Sundays at 4 AM, and a monthly recovery drill on the 1st at 5 AM. All output is logged to `/var/log/mb-backup.log`. Works with any S3-compatible storage: AWS S3, Backblaze B2, Cloudflare R2, Wasabi, MinIO.

### How to test if backup recovery works?

Run `mb backup drill`. It performs a complete recovery drill: takes a fresh backup, restores the latest snapshot to a temporary directory, compares file count and total size between the source and the restore, and writes a pass/fail report to `/var/lib/mb-backup/`. A backup you've never restored is just a hope — drills turn hope into proof. See the [restore drill guide](docs/restore-drill.md).

### How to migrate VPS data to new server?

Run `mb backup export` on the old VPS. It packages `/data/` (all app data), compose configuration files, and all Docker named volumes into a single export directory under `/backup/`. Transfer that directory to the new VPS (via `rsync` or `scp`), then run `mb backup restore --latest` to restore your data. See the [migration guide](docs/migration.md).

## Documentation

- [Backup Strategy Guide](docs/backup-strategy-guide.md) — How to choose between Restic, Kopia, and Borgmatic; S3 vs SFTP
- [Docker Volume Backup](docs/docker-volume-backup.md) — How Docker volume backup and restore works
- [Restore Drill Guide](docs/restore-drill.md) — Why and how to run recovery drills
- [Database Backup Guide](docs/database-backup.md) — Database-aware backup with pre-backup dumps
- [S3 Backend Comparison](docs/backends-comparison.md) — Wasabi vs B2 vs MinIO vs AWS S3: pricing, retention, migration
- [Migration Guide](docs/migration.md) — How to migrate VPS data to a new server

## Related

- [vps-bootstrap](https://github.com/0x10debug/vps-bootstrap) — One-command VPS initialization and security hardening
- [compose-recipes](https://github.com/0x10debug/compose-recipes) — Self-hosted app suites for VPS (the data you'll back up)
- [monitor-stack](https://github.com/0x10debug/monitor-stack) — Lightweight monitoring stack for VPS
- [security-audit](https://github.com/0x10debug/security-audit) — VPS security auditing tool

## License

[MIT](./LICENSE)
