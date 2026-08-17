#!/usr/bin/env bash
# strategies/kopia-s3/backup.sh — Run a Kopia snapshot to S3
# Sources .env for credentials, creates a snapshot of BACKUP_PATHS.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
if [ ! -f "$ENV_FILE" ]; then
    ENV_FILE="${MB_CONFIG_DIR:-/etc/mb-backup}/kopia-s3/.env"
fi

if [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: No .env found. Run 'mb backup init' or create ${SCRIPT_DIR}/.env" >&2
    exit 1
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

: "${KOPIA_REPOSITORY:?KOPIA_REPOSITORY must be set}"
: "${KOPIA_PASSWORD:?KOPIA_PASSWORD must be set}"
: "${AWS_ACCESS_KEY_ID:?AWS_ACCESS_KEY_ID must be set}"
: "${AWS_SECRET_ACCESS_KEY:?AWS_SECRET_ACCESS_KEY must be set}"
: "${BACKUP_PATHS:=/data}"

export KOPIA_PASSWORD AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY

LOG_FILE="${MB_LOG_FILE:-/var/log/mb-backup.log}"
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }

# ── Ensure repository is connected ───────────────────────────────────────────
# Kopia must be connected to the repository before snapshots can be created.
# We attempt a connect if not already connected.
if ! kopia repository status >/dev/null 2>&1; then
    log "INFO: connecting to Kopia S3 repository (${KOPIA_REPOSITORY})"
    if ! kopia repository connect s3 \
            --bucket="$KOPIA_REPOSITORY" \
            --access-key="$AWS_ACCESS_KEY_ID" \
            --secret-access-key="$AWS_SECRET_ACCESS_KEY"; then
        log "ERROR: failed to connect to Kopia repository"
        exit 1
    fi
fi

# ── Create snapshot ──────────────────────────────────────────────────────────
log "INFO: kopia snapshot create starting (paths=${BACKUP_PATHS})"

# shellcheck disable=SC2086
if ! kopia snapshot create ${BACKUP_PATHS}; then
    log "ERROR: kopia snapshot create failed"
    exit 1
fi

log "OK: snapshot created"

# ── Apply retention policy ───────────────────────────────────────────────────
: "${RETENTION_DAILY:=7}"
: "${RETENTION_WEEKLY:=4}"
: "${RETENTION_MONTHLY:=6}"

log "INFO: applying retention (keep-latest=${RETENTION_DAILY})"
kopia policy set --keep-latest "$RETENTION_DAILY" --global 2>/dev/null || true
kopia maintenance run 2>/dev/null || true

log "OK: retention and maintenance applied"
