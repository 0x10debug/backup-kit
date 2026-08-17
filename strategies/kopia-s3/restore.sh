#!/usr/bin/env bash
# strategies/kopia-s3/restore.sh — Restore from a Kopia S3 repository
#
# Usage:
#   restore.sh --snapshot <ID> [--target /path]
#   restore.sh --latest [--target /path]
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

export KOPIA_PASSWORD AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY

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

# Ensure repository is connected
if ! kopia repository status >/dev/null 2>&1; then
    kopia repository connect s3 \
        --bucket="$KOPIA_REPOSITORY" \
        --access-key="$AWS_ACCESS_KEY_ID" \
        --secret-access-key="$AWS_SECRET_ACCESS_KEY"
fi

# Resolve "latest" to an actual snapshot ID
if [ "$SNAPSHOT" = "latest" ]; then
    SNAPSHOT=$(kopia snapshot list --all --json 2>/dev/null \
        | grep -o '"rootID":"[^"]*"' | head -1 | cut -d'"' -f4 || true)
    if [ -z "$SNAPSHOT" ]; then
        echo "ERROR: could not resolve latest snapshot" >&2
        exit 1
    fi
    echo "INFO: latest snapshot resolved to ${SNAPSHOT}"
fi

mkdir -p "$TARGET"

echo "INFO: restoring snapshot '${SNAPSHOT}' to ${TARGET}"
if kopia snapshot restore "$SNAPSHOT" "$TARGET"; then
    echo "OK: restore completed → ${TARGET}"
else
    echo "ERROR: restore failed" >&2
    exit 1
fi
