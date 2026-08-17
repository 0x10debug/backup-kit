# Docker Volume Backup

Docker named volumes are the recommended way to persist container data, but
they can't be backed up with a simple `cp` — the data lives inside Docker's
managed storage area. This guide explains how backup-kit handles it.

## How It Works

Docker volumes are stored under `/var/lib/docker/volumes/` (or the equivalent
OrbStack path on macOS). While you could theoretically copy that directory
directly, it's fragile — Docker may be writing to it, and the internal layout
can change between Docker versions.

The safe approach is to use Docker itself to read the volume. backup-kit
spins up a **temporary alpine container** that mounts the volume read-only,
then streams the contents out as a compressed tar archive.

```
┌─────────────┐     ┌──────────────────┐     ┌──────────────┐
│ Docker       │     │ Temporary alpine │     │ tar.gz       │
│ named volume │────▶│ container (ro)   │────▶│ archive      │
│ /my-data     │     │ tar czf ...      │     │ /backup/     │
└─────────────┘     └──────────────────┘     └──────────────┘
```

## Backing Up a Volume

```bash
# Export a volume to /backup/
docker/volume-backup.sh my-app-data /backup/

# Output: /backup/my-app-data-20260101-030000.tar.gz
```

The script:
1. Verifies the volume exists (`docker volume inspect`)
2. Starts a temporary alpine container with the volume mounted read-only
3. Runs `tar czf` to create a compressed archive
4. Removes the container automatically (`--rm`)
5. Reports the archive size

## Streaming Directly to Restic

If you don't want an intermediate tar.gz file, stream the volume contents
directly into Restic:

```bash
docker/volume-backup.sh my-app-data --restic
```

This pipes the tar stream into `restic backup --stdin`, so the volume data
goes straight into your encrypted Restic repository without touching disk.

## Restoring a Volume

```bash
# Restore an archive into a volume (creates the volume if needed)
docker/volume-restore.sh my-app-data /backup/my-app-data-20260101-030000.tar.gz
```

The script:
1. Creates the volume if it doesn't exist
2. Starts a temporary alpine container with the volume mounted read-write
3. Extracts the archive into the volume
4. Removes the container

## Backing Up an Entire Compose Project

```bash
docker/compose-backup.sh /opt/my-app /backup/my-app-20260101
```

This script:
1. Finds `compose.yml` (or `docker-compose.yml`) in the project directory
2. Parses it to find all declared named volumes
3. Backs up each volume using `volume-backup.sh`
4. Copies `compose.yml`, `.env`, and any override files into the output directory

The result is a self-contained backup of your entire compose project —
configuration and data — ready to restore on the same or a different server.

## Important Notes

- **Stop containers before restoring** — restoring into a volume that a
  running container is using can cause corruption. Stop the container first,
  restore the volume, then start the container again.
- **Bind mounts vs named volumes** — these scripts handle Docker *named
  volumes*. Bind mounts (host directories mapped into containers) are just
  regular directories and are backed up by the main strategy's `BACKUP_PATHS`.
- **Large volumes** — for very large volumes, use `--restic` streaming mode
  to avoid creating a huge intermediate tar.gz file.
- **Permissions** — the alpine container runs as root, so it can read all
  files in the volume regardless of ownership. Restored files retain their
  original permissions and ownership.
