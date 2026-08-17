#!/usr/bin/env bash
# docker/compose-backup.sh — Back up an entire Docker Compose project
#
# Usage:
#   compose-backup.sh <compose-project-dir> [output-dir]
#
# What it does:
#   1. Parses compose.yml / docker-compose.yml for declared volumes
#   2. Backs up each named volume via volume-backup.sh
#   3. Copies compose.yml and .env into the output directory
set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Usage: $0 <compose-project-dir> [output-dir]" >&2
    exit 1
fi

PROJECT_DIR="$1"
OUTPUT_DIR="${2:-/backup/compose-$(date '+%Y%m%d-%H%M%S')}"

if [ ! -d "$PROJECT_DIR" ]; then
    echo "ERROR: project directory not found: ${PROJECT_DIR}" >&2
    exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: docker is not installed" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VOLUME_BACKUP="${SCRIPT_DIR}/volume-backup.sh"

# Locate the compose file
COMPOSE_FILE=""
for candidate in "compose.yml" "compose.yaml" "docker-compose.yml" "docker-compose.yaml"; do
    if [ -f "${PROJECT_DIR}/${candidate}" ]; then
        COMPOSE_FILE="${PROJECT_DIR}/${candidate}"
        break
    fi
done

if [ -z "$COMPOSE_FILE" ]; then
    echo "ERROR: no compose.yml found in ${PROJECT_DIR}" >&2
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

echo "INFO: backing up compose project: ${PROJECT_DIR}"
echo "INFO: compose file: ${COMPOSE_FILE}"
echo "INFO: output: ${OUTPUT_DIR}"

# ── 1. Copy compose config files ─────────────────────────────────────────────
cp "$COMPOSE_FILE" "${OUTPUT_DIR}/"
echo "OK: copied $(basename "$COMPOSE_FILE")"

for extra in ".env" "compose.override.yml" "compose.override.yaml"; do
    if [ -f "${PROJECT_DIR}/${extra}" ]; then
        cp "${PROJECT_DIR}/${extra}" "${OUTPUT_DIR}/"
        echo "OK: copied ${extra}"
    fi
done

# ── 2. Find all named volumes in the compose file ────────────────────────────
# Extract volume names declared under the top-level `volumes:` key.
# This is a lightweight parser: it looks for top-level volume names.
VOLUMES=$(awk '
    /^volumes:/ { in_volumes=1; next }
    /^[a-zA-Z]/ { in_volumes=0 }
    in_volumes && /^  [a-zA-Z_-]+:/ {
        name=$1
        sub(/:.*/, "", name)
        gsub(/^ +/, "", name)
        print name
    }
' "$COMPOSE_FILE")

if [ -z "$VOLUMES" ]; then
    echo "INFO: no named volumes declared in compose file"
else
    echo "INFO: found volumes: $(echo "$VOLUMES" | tr '\n' ' ')"
    for vol in $VOLUMES; do
        echo "---"
        if docker volume inspect "$vol" >/dev/null 2>&1; then
            "$VOLUME_BACKUP" "$vol" "$OUTPUT_DIR" || echo "WARN: failed to back up volume ${vol}"
        else
            # Volume may be prefixed with the project name; try common prefixes
            PROJECT_NAME=$(basename "$PROJECT_DIR")
            if docker volume inspect "${PROJECT_NAME}_${vol}" >/dev/null 2>&1; then
                "$VOLUME_BACKUP" "${PROJECT_NAME}_${vol}" "$OUTPUT_DIR" || echo "WARN: failed to back up volume ${PROJECT_NAME}_${vol}"
            else
                echo "WARN: volume '${vol}' declared but not found on host — skipping"
            fi
        fi
    done
fi

# ── 3. Summary ───────────────────────────────────────────────────────────────
echo ""
echo "OK: compose project backup complete → ${OUTPUT_DIR}"
ARCHIVES=$(find "$OUTPUT_DIR" -name '*.tar.gz' 2>/dev/null | wc -l | tr -d ' ')
echo "INFO: ${ARCHIVES} volume archive(s) created"
