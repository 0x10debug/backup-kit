#!/usr/bin/env bash
# docker/volume-backup.sh — Export a Docker volume as a tar.gz archive
#
# Usage:
#   volume-backup.sh <volume-name> [output-dir]
#   volume-backup.sh <volume-name> --restic   # pipe directly to restic
#
# Uses a temporary alpine container to read the volume (read-only) and
# stream its contents to a compressed tar archive.
set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Usage: $0 <volume-name> [output-dir|--restic]" >&2
    echo "       $0 <volume-name> --restic   # pipe to restic backup" >&2
    exit 1
fi

VOLUME="$1"
MODE="${2:-/backup}"

# Verify Docker is available
if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: docker is not installed" >&2
    exit 1
fi

# Verify the volume exists
if ! docker volume inspect "$VOLUME" >/dev/null 2>&1; then
    echo "ERROR: volume '${VOLUME}' does not exist" >&2
    exit 1
fi

TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"

# ── Mode: pipe directly to restic ────────────────────────────────────────────
if [ "$MODE" = "--restic" ]; then
    echo "INFO: backing up volume '${VOLUME}' directly to restic"
    docker run --rm -v "${VOLUME}:/source:ro" alpine \
        tar czf - -C /source . 2>/dev/null \
        | restic backup --stdin --stdin-filename "volume-${VOLUME}-${TIMESTAMP}.tar.gz"
    echo "OK: volume '${VOLUME}' streamed to restic"
    exit 0
fi

# ── Mode: save to output directory ───────────────────────────────────────────
OUTPUT_DIR="$MODE"
mkdir -p "$OUTPUT_DIR"

OUTPUT_FILE="${OUTPUT_DIR}/${VOLUME}-${TIMESTAMP}.tar.gz"

echo "INFO: exporting volume '${VOLUME}' → ${OUTPUT_FILE}"

docker run --rm \
    -v "${VOLUME}:/source:ro" \
    -v "${OUTPUT_DIR}:/dest" \
    alpine \
    tar czf "/dest/${VOLUME}-${TIMESTAMP}.tar.gz" -C /source .

if [ -f "$OUTPUT_FILE" ]; then
    SIZE=$(du -h "$OUTPUT_FILE" | cut -f1)
    echo "OK: volume '${VOLUME}' exported (${SIZE}) → ${OUTPUT_FILE}"
else
    echo "ERROR: export failed — output file not created" >&2
    exit 1
fi
