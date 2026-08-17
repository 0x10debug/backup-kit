#!/usr/bin/env bash
# docker/volume-restore.sh — Import a tar.gz archive into a Docker volume
#
# Usage:
#   volume-restore.sh <volume-name> <archive.tar.gz>
#
# If the volume does not exist, it is created. Existing contents are
# overwritten by the archive contents.
set -euo pipefail

if [ $# -lt 2 ]; then
    echo "Usage: $0 <volume-name> <archive.tar.gz>" >&2
    exit 1
fi

VOLUME="$1"
ARCHIVE="$2"

if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: docker is not installed" >&2
    exit 1
fi

if [ ! -f "$ARCHIVE" ]; then
    echo "ERROR: archive file not found: ${ARCHIVE}" >&2
    exit 1
fi

# Create the volume if it doesn't exist
if ! docker volume inspect "$VOLUME" >/dev/null 2>&1; then
    echo "INFO: creating volume '${VOLUME}'"
    docker volume create "$VOLUME" >/dev/null
fi

# Resolve absolute path to archive for bind-mounting
ARCHIVE_ABS="$(cd "$(dirname "$ARCHIVE")" && pwd)/$(basename "$ARCHIVE")"

echo "INFO: restoring '${ARCHIVE}' into volume '${VOLUME}'"

docker run --rm \
    -v "${VOLUME}:/target" \
    -v "${ARCHIVE_ABS}:/source/archive.tar.gz:ro" \
    alpine \
    sh -c 'cd /target && tar xzf /source/archive.tar.gz'

echo "OK: archive restored into volume '${VOLUME}'"
