#!/usr/bin/env bash
# strategies/borgmatic/restore.sh — Restore from a Borg repository via borgmatic
#
# Usage:
#   restore.sh --snapshot <ARCHIVE> [--target /path]
#   restore.sh --latest [--target /path]
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

SNAPSHOT=""
TARGET="/tmp/mb-restore/"

while [ $# -gt 0 ]; do
    case "$1" in
        --snapshot) SNAPSHOT="$2"; shift 2 ;;
        --latest)   SNAPSHOT="latest"; shift ;;
        --target)   TARGET="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: $0 --snapshot <ARCHIVE> [--target /path]"
            echo "       $0 --latest [--target /path]"
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

if [ -z "$SNAPSHOT" ]; then
    echo "ERROR: Specify --snapshot <ARCHIVE> or --latest" >&2
    exit 1
fi

# Resolve "latest" to the most recent archive name
if [ "$SNAPSHOT" = "latest" ]; then
    SNAPSHOT=$(borg list --short "${BORG_REPO}" 2>/dev/null | tail -1 || true)
    if [ -z "$SNAPSHOT" ]; then
        echo "ERROR: could not resolve latest archive" >&2
        exit 1
    fi
    echo "INFO: latest archive resolved to ${SNAPSHOT}"
fi

mkdir -p "$TARGET"

echo "INFO: extracting archive '${SNAPSHOT}' from ${BORG_REPO} to ${TARGET}"
if borg extract "${BORG_REPO}::${SNAPSHOT}" --output-dir "$TARGET"; then
    echo "OK: restore completed → ${TARGET}"
else
    echo "ERROR: restore failed" >&2
    exit 1
fi
