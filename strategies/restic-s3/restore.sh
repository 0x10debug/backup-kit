#!/usr/bin/env bash
# strategies/restic-s3/restore.sh — Restore from a Restic S3 repository
#
# Usage:
#   restore.sh --snapshot <ID> [--target /path]
#   restore.sh --latest [--target /path]
#
# Defaults: target = /tmp/mb-restore/
set -euo pipefail

# ── Locate config ────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
if [ ! -f "$ENV_FILE" ]; then
    ENV_FILE="${MB_CONFIG_DIR:-/etc/mb-backup}/restic-s3/.env"
fi

if [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: No .env found. Run 'mb backup init' or create ${SCRIPT_DIR}/.env" >&2
    exit 1
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

: "${RESTIC_REPOSITORY:?RESTIC_REPOSITORY must be set}"
: "${RESTIC_PASSWORD:?RESTIC_PASSWORD must be set}"
: "${AWS_ACCESS_KEY_ID:?AWS_ACCESS_KEY_ID must be set}"
: "${AWS_SECRET_ACCESS_KEY:?AWS_SECRET_ACCESS_KEY must be set}"

export RESTIC_REPOSITORY RESTIC_PASSWORD AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY

# ── Parse args ───────────────────────────────────────────────────────────────
SNAPSHOT=""
TARGET="/tmp/mb-restore/"

while [ $# -gt 0 ]; do
    case "$1" in
        --snapshot) SNAPSHOT="$2"; shift 2 ;;
        --latest)   SNAPSHOT="latest"; shift ;;
        --target)   TARGET="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: $0 --snapshot <ID> [--target /path]"
            echo "       $0 --latest [--target /path]"
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

if [ -z "$SNAPSHOT" ]; then
    echo "ERROR: Specify --snapshot <ID> or --latest" >&2
    exit 1
fi

# ── Restore ──────────────────────────────────────────────────────────────────
mkdir -p "$TARGET"

echo "INFO: restoring snapshot '${SNAPSHOT}' to ${TARGET}"
if restic restore "$SNAPSHOT" --target "$TARGET"; then
    echo "OK: restore completed → ${TARGET}"
else
    echo "ERROR: restore failed" >&2
    exit 1
fi
