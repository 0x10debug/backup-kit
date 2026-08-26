# S3 Backend Comparison — Wasabi vs Backblaze B2 vs MinIO vs AWS S3

How to choose an S3-compatible storage backend for the `restic-s3` strategy.
This guide compares the four most common backends backup-kit supports and
explains retention, migration, and security for each.

## TL;DR — Which backend should I pick?

| If you want… | Use |
|---|---|
| Cheapest cloud, no egress fees, simple flat pricing | **Wasabi** |
| Cheapest cloud storage, fine with paying egress on restores | **Backblaze B2** |
| Full control, zero cloud fees, data stays on your hardware | **MinIO** (self-hosted) |
| Maximum durability/region choice, fine with AWS pricing | **AWS S3** |
| A second media for the 3-2-1 rule without a cloud account | **MinIO** on a second VPS/NAS |

All four work with the same `strategies/restic-s3/` backup and restore
scripts — only the credentials and endpoint differ. Templates for Wasabi,
B2, and MinIO live in `strategies/restic-s3/` (`wasabi.env.example`,
`b2.env.example`, `minio.env.example`).

## Comparison Table

| | **AWS S3** | **Wasabi** | **Backblaze B2** | **MinIO** (self-hosted) |
|---|---|---|---|---|
| **Type** | Managed cloud (origin) | Managed cloud, S3-compatible | Managed cloud, native B2 + S3-compat | Self-hosted, S3-compatible |
| **Restic scheme** | `s3:` | `s3:` | `b2:` (native) or `s3:` (compat) | `s3:` |
| **Storage price** (≈, check vendor) | ~$0.023/GB/mo (Standard) | ~$0.0069/GB/mo flat | ~$0.006/GB/mo | $0 (your hardware) |
| **Egress cost** | ~$0.09/GB | **$0** (no egress fees) | Free up to ~1GB/day, then ~$0.01/GB | $0 (your bandwidth) |
| **API request fees** | Yes (PUT/GET/DELETE) | None (within fair use) | Class B/C transaction fees | None |
| **Durability** | 99.999999999% (11×9) | 11×9 | 99.999999999% (11×9) | Depends on your setup (RAID/erasure-coding) |
| **Availability SLA** | 99.9% (Standard) | 99.9% | 99.9% | None — your responsibility |
| **Min storage duration** | None (Standard) | **90 days** | None | None |
| **Regions** | 30+ globally | ~9 regions | 2 regions (US, EU) | Wherever you deploy |
| **TLS** | Automatic | Automatic | Automatic | You configure (required) |
| **Best for** | Existing AWS users, multi-region | Frequent restores, cost-sensitive | Large cold backups, budget | Privacy/control, 3-2-1 second media |
| **Worst for** | Cost-sensitive, frequent restores | Very short-lived snapshots (<90d) | Frequent large restores (egress) | You don't want to operate storage |

> Prices change — verify on the vendor's pricing page before committing.
> The table gives order-of-magnitude comparisons for planning.

## Backend Details

### AWS S3 (the reference backend)

The original S3. Highest durability, most regions, deepest ecosystem. Also
the most expensive for backup workloads once you factor in egress and request
fees. Use it if you're already in AWS, need a specific region/compliance, or
want the most battle-tested option. Configure with the base
`strategies/restic-s3/.env.example`.

- **Endpoint:** `s3.amazonaws.com` (or a region-specific endpoint)
- **Auth:** IAM Access Key + Secret Key
- **Gotchas:** Egress on restore drills adds up; consider S3 Lifecycle rules
  to move old snapshots to S3 Glacier for cheaper long-term storage (note:
  Glacier has retrieval delays and fees — test a restore before relying on it).

### Wasabi

S3-compatible, flat low price, and **no egress fees** — which makes restore
drills and actual restores free. The trade-off is a **90-day minimum storage
duration** per object: objects deleted before 90 days still incur the
remaining storage charge. This matters for retention policy design.

- **Endpoint:** region-specific, e.g. `s3.us-east-1.wasabisys.com`
- **Auth:** Wasabi Access Key + Secret Key (created in the console)
- **Template:** `strategies/restic-s3/wasabi.env.example`
- **Retention:** `strategies/restic-s3/wasabi-retention.conf`
  (7 daily + 4 weekly + 6 monthly + 1 yearly)
- **Gotchas:**
  - Keep `--keep-daily` at 7+ so daily-tier churn doesn't hit the 90-day
    minimum repeatedly. Monthly/yearly tiers comfortably exceed 90 days.
  - "No egress fees" is within fair use; sustained massive downloads can be
    throttled. Fine for normal backup/restore cycles.
  - Bucket names are globally unique within Wasabi.

### Backblaze B2

Cheapest raw storage among managed clouds, with a native B2 API that Restic
supports directly (`b2:` scheme) — preferred over B2's S3-compatibility layer
for new repos. Charges egress above a free daily quota, so large restore
drills cost money.

- **Endpoint (native):** none — use `b2:<bucket>:<path>`
- **Endpoint (S3-compat):** `s3.<region>.backblazeb2.com`
- **Auth (native):** B2 Application Key ID + Application Key (scoped to one bucket)
- **Auth (S3-compat):** S3-compatible keys generated in the B2 console
- **Template:** `strategies/restic-s3/b2.env.example`
- **Retention:** `strategies/restic-s3/b2-retention.conf`
  (7 daily + 4 weekly + 6 monthly + 1 yearly)
- **Gotchas:**
  - **Never use the master account key.** Create a bucket-scoped App Key.
  - Native `b2:` mode is faster and gives better error messages than S3-compat.
  - Class B/C transaction fees (small-object metadata ops) add up if you back
    up huge numbers of tiny files; Restic's chunking mitigates this.
  - Object Lock / immutability interacts badly with `restic forget --prune`
    (locked objects can't be pruned). Only enable it if you understand the
    interaction, and set lock windows shorter than your shortest retention tier.

### MinIO (self-hosted)

MinIO is an S3-compatible server you run yourself — on a second VPS, a home
server, or a NAS. Zero per-GB cloud fees (you pay for hardware/bandwidth),
full data sovereignty, and an excellent fit for the 3-2-1 rule's "second
media" copy. The trade-off: you are responsible for durability and TLS.

- **Endpoint:** your server, e.g. `https://minio.example.com:9000`
- **Auth:** MinIO Access Key + Secret Key (create a scoped user, not root)
- **Template:** `strategies/restic-s3/minio.env.example`
- **Retention:** `strategies/restic-s3/minio-retention.conf`
  (7 daily + 4 weekly + 6 monthly + 1 yearly)
- **Server template:** `strategies/restic-s3/minio-docker-compose.yml`
  (pinned `minio:RELEASE.2024-10-13T13-34-11Z`, ports 9000/9001, healthcheck)
- **Gotchas:**
  - **TLS is required** for Restic's S3 client. Use a real cert (Let's
    Encrypt) or export your self-signed CA via `AWS_CA_BUNDLE`. Do not disable
    verification in production.
  - Run MinIO on a **different host** than the data you back up — a single
    host failing must not take out both data and backup.
  - Single-node MinIO is fine as a secondary target but offers no bit-rot
    protection. For durability, run MinIO in **distributed/erasure-coded**
    mode across multiple drives/nodes.
  - Enable **bucket versioning** for protection against accidental deletes.
  - Monitor disk usage — MinIO won't auto-grow volumes; alert before it fills.

## Retention Policy Recommendations

All templates default to **7 daily + 4 weekly + 6 monthly + 1 yearly**
(≈18 retained snapshots). Restic deduplicates, so retained snapshots share
data and the marginal cost of keeping more is mostly metadata.

| Backend | Suggested starting policy | Why |
|---|---|---|
| AWS S3 | 7d / 4w / 6m | Egress cost makes frequent restores pricey; keep monthly tier modest and consider Glacier for yearly. |
| Wasabi | 7d / 4w / 6m / 1y | No egress → cheap restores; 90-day min duration → keep daily tier ≥7 so churn doesn't pay twice. |
| B2 | 7d / 4w / 6m / 1y | Cheap storage, metered egress; monthly/yearly tiers are nearly free with dedup. |
| MinIO | 7d / 4w / 6m / 1y | No cost constraint; limited only by your disk. Be generous if you have space. |

Apply a policy with:

```bash
restic forget --keep-daily 7 --keep-weekly 4 \
    --keep-monthly 6 --keep-yearly 1 --prune
```

Or use `mb backup cleanup`, which reads `RETENTION_*` from your strategy env.

## Migrating Between Backends (`restic copy`)

Restic can copy snapshots from one repository to another with `restic copy`.
This is the recommended way to migrate between backends (e.g. AWS S3 → Wasabi,
or Wasabi → MinIO) without re-reading all your source data from disk. The
`scripts/backend-migrate.sh` helper wraps this with dry-run and progress.

### How `restic copy` works

1. You initialize a **destination** repo with the same `RESTIC_PASSWORD` as
   the source (snapshots are copied as-is; the password must match for the
   copy to be readable — or use `--from-password-file`/`--password-file` if
   they differ).
2. `restic copy` reads each snapshot from the source and writes its
   deduplicated blobs to the destination. Data already present in the
   destination is skipped, so re-runs are cheap.
3. After the copy, run `restic snapshots` in the destination to verify, then
   switch your strategy env to point at the new backend.

### Using the migration helper

```bash
# Preview what would be copied (no data written)
scripts/backend-migrate.sh \
    --from-env /etc/mb-backup/restic-s3/.env \
    --to-env   /path/to/wasabi.env \
    --dry-run

# Perform the migration
scripts/backend-migrate.sh \
    --from-env /etc/mb-backup/restic-s3/.env \
    --to-env   /path/to/wasabi.env

# Copy only specific snapshots / paths / tags
scripts/backend-migrate.sh \
    --from-env source.env --to-env dest.env \
    --snapshot a1b2c3d4 --tag prod
```

See `scripts/backend-migrate.sh --help` for all options. The script supports
`--dry-run`, per-snapshot progress, and a final verification step.

### Migration checklist

- [ ] Initialize destination repo (`restic init`) with a known password
- [ ] `restic copy --dry-run` (via the helper) to preview
- [ ] Run the real `restic copy`
- [ ] `restic snapshots` in destination matches source count
- [ ] `restic check` passes in destination
- [ ] Run a restore drill against the destination (`mb backup restore-test`)
- [ ] Update strategy env to point at the destination
- [ ] Keep the source for a grace period before decommissioning

## Encryption and Security

All four backends receive **client-side encrypted** data from Restic — the
storage provider (or, for MinIO, anyone with disk access) only sees
ciphertext. Key points that apply regardless of backend:

- **Restic encrypts data and metadata** with your `RESTIC_PASSWORD`
  (AES-256, Poly1305). The password never leaves your VPS.
- **Lose the password, lose the backup.** Store it in a password manager and
  keep an offline copy. Backends cannot recover it for you.
- **Use scoped credentials**, not root/master keys:
  - AWS: an IAM user restricted to the backup bucket.
  - Wasabi: a per-bucket access key.
  - B2: a bucket-scoped App Key (never the master key).
  - MinIO: a dedicated backup user, not the root credentials.
- **TLS in transit** is mandatory: AWS/Wasabi/B2 do it automatically; for
  MinIO you must configure it yourself (see `minio.env.example`).
- **At rest**, the cloud backends also encrypt server-side, but this is
  defense-in-depth — your Restic encryption is the real protection.
- **Immutability / Object Lock**: AWS S3 and B2 support it. It can protect
  against ransomware deleting your backups, but it conflicts with
  `restic forget --prune`. Only enable it if you understand the interaction
  and set lock windows shorter than your shortest retention tier.
- **Don't store the password in the same place as the backup.** A backup env
  file containing both credentials and the encryption password, kept on the
  same host as the data, is a single point of failure. Keep the password
  somewhere separate (password manager, offline printout).

## Choosing for the 3-2-1 Rule

The 3-2-1 rule: **3** copies, on **2** different media, with **1** off-site.

A common backup-kit setup that satisfies 3-2-1:

1. **Copy 1:** live data on your VPS (`/data/`).
2. **Copy 2:** Restic repo on a cloud backend (Wasabi/B2/AWS S3) — off-site.
3. **Copy 3:** Restic repo on a MinIO server at home/second VPS — second media.

Run `mb backup compliance` to audit your setup against the rule. Use
`scripts/backend-migrate.sh` (or `restic copy` in cron) to keep the second
backend in sync with the first.
