#!/usr/bin/env bash
# strategies/restic-s3/backup.sh — Run a Restic backup to S3
# Sources .env for credentials, backs up BACKUP_PATHS, applies retention.
set -euo pipefail

# ── Locate config ────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

# Fall back to deployed config location
if [ ! -f "$ENV_FILE" ]; then
    ENV_FILE="${MB_CONFIG_DIR:-/etc/mb-backup}/restic-s3/.env"
fi

if [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: No .env found. Run 'mb backup init' or create ${SCRIPT_DIR}/.env" >&2
    exit 1
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

# ── Defaults ─────────────────────────────────────────────────────────────────
: "${RESTIC_REPOSITORY:?RESTIC_REPOSITORY must be set}"
: "${RESTIC_PASSWORD:?RESTIC_PASSWORD must be set}"
: "${AWS_ACCESS_KEY_ID:?AWS_ACCESS_KEY_ID must be set}"
: "${AWS_SECRET_ACCESS_KEY:?AWS_SECRET_ACCESS_KEY must be set}"
: "${BACKUP_PATHS:=/data}"
: "${RETENTION_DAILY:=7}"
: "${RETENTION_WEEKLY:=4}"
: "${RETENTION_MONTHLY:=6}"

export RESTIC_REPOSITORY RESTIC_PASSWORD AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY

LOG_FILE="${MB_LOG_FILE:-/var/log/mb-backup.log}"
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }

# ── Run backup ───────────────────────────────────────────────────────────────
log "INFO: restic backup starting (repo=${RESTIC_REPOSITORY}, paths=${BACKUP_PATHS})"

if ! restic backup ${BACKUP_PATHS}; then
    log "ERROR: restic backup failed"
    exit 1
fi

log "OK: backup completed"

# ── Apply retention ──────────────────────────────────────────────────────────
log "INFO: applying retention (daily=${RETENTION_DAILY} weekly=${RETENTION_WEEKLY} monthly=${RETENTION_MONTHLY})"

if ! restic forget \
        --keep-daily "$RETENTION_DAILY" \
        --keep-weekly "$RETENTION_WEEKLY" \
        --keep-monthly "$RETENTION_MONTHLY" \
        --prune; then
    log "WARN: restic forget/prune failed — backup is safe but old snapshots not cleaned"
    exit 2
fi

log "OK: retention applied and repository pruned"
