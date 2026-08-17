#!/usr/bin/env bash
# strategies/borgmatic/backup.sh — Run a Borgmatic backup
# Sources .env for credentials, then invokes borgmatic (which reads strategy.conf).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
if [ ! -f "$ENV_FILE" ]; then
    ENV_FILE="${MB_CONFIG_DIR:-/etc/mb-backup}/borgmatic/.env"
fi

if [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: No .env found. Run 'mb backup init' or create ${SCRIPT_DIR}/.env" >&2
    exit 1
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

: "${BORG_REPO:?BORG_REPO must be set}"
: "${BORG_PASSPHRASE:?BORG_PASSPHRASE must be set}"

export BORG_REPO BORG_PASSPHRASE

LOG_FILE="${MB_LOG_FILE:-/var/log/mb-backup.log}"
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }

# ── Locate borgmatic config ──────────────────────────────────────────────────
# Prefer the strategy.conf in this directory; fall back to deployed locations.
CONFIG="${SCRIPT_DIR}/strategy.conf"
if [ ! -f "$CONFIG" ]; then
    CONFIG="${MB_CONFIG_DIR:-/etc/mb-backup}/borgmatic/strategy.conf"
fi
if [ ! -f "$CONFIG" ]; then
    CONFIG="/etc/borgmatic/config.yaml"
fi

if [ ! -f "$CONFIG" ]; then
    log "ERROR: borgmatic config not found (looked in ${SCRIPT_DIR}/strategy.conf and /etc/borgmatic/config.yaml)"
    exit 1
fi

# ── Run borgmatic ────────────────────────────────────────────────────────────
log "INFO: borgmatic backup starting (repo=${BORG_REPO}, config=${CONFIG})"

if ! borgmatic --config "$CONFIG"; then
    log "ERROR: borgmatic backup failed"
    exit 1
fi

log "OK: borgmatic backup completed (create + prune + check)"
