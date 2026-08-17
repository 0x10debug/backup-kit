# Backup Strategy Guide

Choosing the right backup tool and backend for your VPS. This guide compares
Restic, Kopia, and Borgmatic, and helps you decide between S3-compatible cloud
storage and SFTP to another server.

## The Tools

### Restic

Restic is a fast, secure, modern backup program with built-in client-side
encryption (AES-256), deduplication, and snapshot management.

**Strengths:**
- Excellent deduplication — only changed blocks are stored
- Strong encryption — data and metadata encrypted before upload
- Simple CLI — no daemon, no server component
- Multiple backends — S3, SFTP, local, REST server, Azure, Google Cloud
- Mature and widely deployed

**Best for:** Most VPS users. If you're unsure, start with `restic-s3`.

### Kopia

Kopia is a deduplicated, encrypted backup tool with an optional Web GUI for
browsing and restoring snapshots.

**Strengths:**
- Web GUI — browse snapshots, restore individual files from a browser
- Fast incremental backups with content-addressable storage
- Cross-platform — works on Linux, macOS, Windows
- Built-in scheduling and policy management

**Best for:** Users who want a visual interface to browse and restore backups,
or who manage backups across multiple machines.

### Borgmatic (Borg)

Borgmatic is a YAML-config wrapper around Borg Backup, offering declarative
configuration with excellent compression.

**Strengths:**
- YAML declarative config — everything in one readable file
- Excellent compression (zstd, lz4) — saves storage space
- Battle-tested — Borg has years of production use
- Strong encryption and deduplication

**Best for:** Users who prefer declarative YAML configuration and want the
best compression ratios.

## The Backends

### S3-Compatible Cloud Storage

S3 is the most flexible backend. It works with:

| Provider | Notes |
|---|---|
| AWS S3 | The original. Most expensive, most reliable. |
| Backblaze B2 | Cheap, reliable, S3-compatible API. Popular for backups. |
| Cloudflare R2 | No egress fees. Great if you also use Cloudflare. |
| Wasabi | Cheapest, no egress fees, some fair-use limits. |
| MinIO | Self-hosted S3. Run it on another VPS for full control. |

**Pros:**
- No server to maintain — the cloud provider handles durability
- Geographic separation — your backups are off-site by definition
- Scales infinitely — pay for what you use

**Cons:**
- Ongoing cost (though often under $5/month for VPS backups)
- Requires internet bandwidth for every backup
- You trust the provider with your (encrypted) data

**Choose S3 if:** You want off-site backups without managing a second server.

### SFTP (Another VPS)

Use SSH/SFTP to store backups on another VPS you control.

**Pros:**
- No cloud costs — you already pay for the second VPS
- Full control — your data never touches a third party
- Fast if both VPS are in the same datacenter

**Cons:**
- You must maintain the storage server (updates, disk space, monitoring)
- Not truly off-site if both VPS are with the same provider
- Disk space is limited by the second VPS's storage

**Choose SFTP if:** You already have a second VPS, or you don't want any cloud
dependency.

## Decision Matrix

| Your Situation | Recommended Strategy |
|---|---|
| Just want it to work, happy to pay a few $/month | `restic-s3` (Backblaze B2) |
| Have a second VPS, no cloud account | `restic-sftp` |
| Want a Web GUI to browse/restore | `kopia-s3` |
| Prefer YAML config, want best compression | `borgmatic` |
| Self-hosting everything, no cloud at all | `restic-sftp` + MinIO on second VPS |

## Retention Policy

All strategies default to **7 daily + 4 weekly + 6 monthly** snapshots. This
means:

- You can restore any day from the last week
- You can restore any week from the last month
- You can restore any month from the last six months

This gives you about **17 snapshots** retained at any time — enough to recover
from accidental deletion (noticed within a week), a bad update (noticed within
a month), or data corruption (noticed within six months).

Adjust in `strategy.conf` or `.env`:

```bash
RETENTION_DAILY=14      # keep two weeks of daily snapshots
RETENTION_WEEKLY=8      # keep two months of weekly snapshots
RETENTION_MONTHLY=12    # keep a year of monthly snapshots
```

## Combining with Docker

If your VPS runs Docker Compose apps (via [compose-recipes](https://github.com/0x10debug/compose-recipes)),
all app data lives under `/data/`. The default `BACKUP_PATHS=/data` covers
everything. For Docker named volumes that live outside `/data/`, use the
[Docker volume backup scripts](../docker/).
