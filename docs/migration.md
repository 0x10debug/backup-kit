# Migration Guide

How to move all your VPS data to a new server using backup-kit.

## Overview

VPS migration means moving three things:

1. **App data** — everything under `/data/` (databases, files, configs)
2. **Docker volumes** — named volumes not under `/data/`
3. **Compose configuration** — `compose.yml`, `.env`, override files

`mb backup export` packages all three into a single directory you can transfer
to the new server.

## Step 1: Export on the Old VPS

```bash
# Export everything to /backup/mb-export-<timestamp>/
mb backup export

# Or specify a custom output location
mb backup export /tmp/migration
```

The export directory contains:

```
mb-export-20260101-030000/
├── data/                  # Copy of /data/ (all app data)
├── compose/               # Compose config files (if found)
├── volumes/               # Docker named volume archives (*.tar.gz)
├── backup-config/         # Backup strategy config (secrets redacted)
└── MANIFEST.txt           # Export metadata (date, strategy, hostname)
```

**Note:** The strategy config in `backup-config/.env` has secrets redacted.
You'll need to re-enter credentials on the new server.

## Step 2: Transfer to the New VPS

```bash
# From the old VPS, push to the new one
rsync -avz --progress /backup/mb-export-* user@new-vps:/tmp/migration/

# Or from the new VPS, pull from the old one
rsync -avz --progress user@old-vps:/backup/mb-export-* /tmp/migration/
```

For large datasets, use `rsync` with compression and run it in a `tmux`
session so a dropped SSH connection doesn't kill the transfer:

```bash
tmux new -s migration
rsync -avz --compress --progress --partial \
    user@old-vps:/backup/mb-export-* /tmp/migration/
# Ctrl+B then D to detach; tmux attach -t migration to reattach
```

## Step 3: Prepare the New VPS

On the new server:

```bash
# 1. Harden the new VPS and install Docker
# → https://github.com/0x10debug/vps-bootstrap

# 2. Install backup-kit
git clone https://github.com/0x10debug/backup-kit.git
cd backup-kit

# 3. Initialize your backup strategy (re-enter credentials)
./mb backup init
```

## Step 4: Restore Data

```bash
# Restore app data to /data/
cp -a /tmp/migration/mb-export-*/data/* /data/

# Restore Docker volumes
for archive in /tmp/migration/mb-export-*/volumes/*.tar.gz; do
    volname=$(basename "$archive" | sed 's/-[0-9]*-[0-9]*\.tar\.gz//')
    docker/volume-restore.sh "$volname" "$archive"
done

# Restore compose configs
cp -a /tmp/migration/mb-export-*/compose/* /opt/compose/
```

## Step 5: Start Your Services

```bash
# If using compose-recipes
cd /opt/compose/my-app
docker compose up -d

# Verify everything is running
docker compose ps
```

## Step 6: Verify the Migration

```bash
# Check that data is present
ls -la /data/

# Run a backup verify on the new server
mb backup verify

# Run a recovery drill to confirm everything works
mb backup drill
```

## Alternative: Restore from Backup Repository

If your backup repository (S3/SFTP) is already accessible from the new VPS,
you can skip the export/import entirely and restore directly:

```bash
# Initialize backup-kit with the same repository
./mb backup init
# → use the same RESTIC_REPOSITORY and RESTIC_PASSWORD

# Restore the latest snapshot
mb backup restore --latest --target /data

# Or restore a specific snapshot
mb backup list
mb backup restore --snapshot a1b2c3d4 --target /data
```

This is faster if your backup repository is cloud-based (S3) — no need to
transfer a large export directory over SSH.

## Post-Migration Checklist

- [ ] All app data restored to `/data/`
- [ ] All Docker volumes restored
- [ ] Compose configs in place
- [ ] All containers running (`docker compose ps`)
- [ ] Apps accessible via reverse proxy
- [ ] Backup strategy re-initialized on new VPS
- [ ] Test backup runs successfully (`mb backup run`)
- [ ] Recovery drill passes (`mb backup drill`)
- [ ] Update DNS to point to new VPS IP
- [ ] Decommission old VPS (after confirming everything works for a few days)

## Tips

- **Don't delete the old VPS immediately** — keep it running for a few days
  as a fallback in case you discover a problem with the migration.
- **Export to the backup repository too** — `mb backup export` creates a local
  copy, but you should also ensure your regular backup ran successfully on the
  old VPS before decommissioning it.
- **Test on the new VPS before switching DNS** — get everything running, test
  your apps, then update DNS. This minimizes downtime.
