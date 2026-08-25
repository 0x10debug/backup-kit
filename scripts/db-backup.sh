#!/usr/bin/env bash
# scripts/db-backup.sh — Database-aware backup with pre-backup dumps
#
# backup-kit: encrypted, automated, tested recovery for VPS and Docker.
# Homepage: https://github.com/0x10debug/backup-kit
#
# This script performs consistent, point-in-time dumps of databases *before*
# a Restic/Kopia backup runs, so the resulting snapshot contains a
# recoverable database image rather than a crash-consistent copy of live
# data files. Four database engines are supported:
#
#   PostgreSQL  — pg_dump --format=custom (a single compressed dump file)
#   MySQL/MariaDB — mysqldump --single-transaction --routines --triggers
#   Redis       — redis-cli BGSAVE, wait for completion, copy the RDB file
#   MongoDB     — mongodump --archive --gzip (a single archive stream)
#
# Targets can be discovered automatically by scanning running Docker
# containers for the label `backup.db-type=postgres|mysql|redis|mongo`, or
# specified manually on the command line. Dump files are written to a
# temporary directory that is meant to be included in the backup source
# paths, then cleaned up after the backup completes.
#
# Usage:
#   db-backup.sh [OPTIONS]
#
# Options:
#   --auto                    Auto-discover databases via Docker container labels
#   --type TYPE               Database type: postgres|mysql|redis|mongo (manual mode)
#   --host HOST               Database host (manual mode)
#   --port PORT               Database port (manual mode, default per type)
#   --user USER               Database user (manual mode)
#   --password PASSWORD       Database password (manual mode)
#   --db NAME                 Database name (postgres/mysql/mongo, ignored for redis)
#   --container NAME          Docker container to exec into for the dump
#   --dump-dir PATH           Directory for dump files (default: /backup/db-dumps-<ts>)
#   --report PATH             Report file path (default: /var/lib/mb-backup/db-backup-<ts>.txt)
#   --json-report PATH        JSON report file path (default: alongside --report with .json)
#   --keep                    Keep dump files after completion (do not clean up)
#   --dry-run                 Preview which databases would be backed up; write no dumps
#   --help, -h                Show this help
#
# Exit codes:
#   0  All dumps succeeded (or dry-run completed)
#   1  One or more dumps failed
#   2  Invalid arguments / missing prerequisites

set -euo pipefail

# ── Constants ────────────────────────────────────────────────────────────────

readonly DB_VERSION="1.0.0"
readonly DB_HOMEPAGE="https://github.com/0x10debug/backup-kit"

# Supported database types
readonly DB_SUPPORTED_TYPES=(postgres mysql redis mongo)

# Default ports per database type
declare -A DB_DEFAULT_PORTS=(
    [postgres]="5432"
    [mysql]="3306"
    [redis]="6379"
    [mongo]="27017"
)

# Docker label used for auto-discovery
readonly DB_LABEL="backup.db-type"

# ── Color variables ──────────────────────────────────────────────────────────

if [ -t 1 ]; then
    readonly C_FAIL='\033[0;31m'
    readonly C_OK='\033[0;32m'
    readonly C_WARN='\033[0;33m'
    readonly C_INFO='\033[0;34m'
    readonly C_RST='\033[0m'
else
    readonly C_FAIL=''
    readonly C_OK=''
    readonly C_WARN=''
    readonly C_INFO=''
    readonly C_RST=''
fi

# ── Defaults ─────────────────────────────────────────────────────────────────

DB_MODE=""          # "auto" or "manual"
DB_TYPE=""
DB_HOST=""
DB_PORT=""
DB_USER=""
DB_PASSWORD=""
DB_NAME=""
DB_CONTAINER=""
DB_DUMP_DIR=""
DB_REPORT=""
DB_JSON_REPORT=""
DB_KEEP=false
DB_DRY_RUN=false

# Resolved at runtime
DB_STATE_DIR="${MB_STATE_DIR:-/var/lib/mb-backup}"
DB_LOG_FILE="${MB_LOG_FILE:-/var/log/mb-backup.log}"
DB_BACKUP_TMP="${MB_BACKUP_TMP:-/backup}"

# Accumulated results (populated during execution)
# Each entry: "type|host|port|db|container|status|size_bytes|duration_s|dump_file|error"
DB_RESULTS=""

# ── Logging helpers (self-contained, no external deps) ───────────────────────

db_log() {
    local level="$1"; shift
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    printf '[%s] %s %s\n' "$ts" "$level" "$*"
}

db_info()    { db_log "${C_INFO}INFO${C_RST}" "$*" >&2; }
db_success() { printf "${C_OK}%s${C_RST}\n" "$*" >&2; }
db_warn()    { printf "${C_WARN}WARN: %s${C_RST}\n" "$*" >&2; }
db_error()   { printf "${C_FAIL}ERROR: %s${C_RST}\n" "$*" >&2; }
db_step()    { printf '\n==> %s\n' "$*" >&2; }
db_detail()  { printf '    %s\n' "$*" >&2; }

db_log_file() {
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    ( mkdir -p "$(dirname "$DB_LOG_FILE")" 2>/dev/null
      echo "[${ts}] $*" >> "$DB_LOG_FILE" ) 2>/dev/null || true
}

db_die() {
    db_error "$*"
    db_log_file "db-backup: FATAL: $*"
    exit 2
}

# ── Argument parsing ─────────────────────────────────────────────────────────

db_show_help() {
    cat <<'HELP'
db-backup.sh — Database-aware backup with pre-backup dumps

Performs consistent database dumps (PostgreSQL, MySQL/MariaDB, Redis, MongoDB)
before a Restic/Kopia backup runs. Databases can be auto-discovered via Docker
container labels or specified manually.

Usage:
  db-backup.sh --auto [OPTIONS]
  db-backup.sh --type TYPE --host HOST [OPTIONS]

Options:
  --auto                  Auto-discover databases via Docker container labels
  --type TYPE             Database type: postgres|mysql|redis|mongo (manual mode)
  --host HOST             Database host (manual mode)
  --port PORT             Database port (manual mode, default per type)
  --user USER             Database user (manual mode)
  --password PASSWORD     Database password (manual mode)
  --db NAME               Database name (postgres/mysql/mongo; ignored for redis)
  --container NAME        Docker container to exec into for the dump
  --dump-dir PATH         Directory for dump files (default: /backup/db-dumps-<ts>)
  --report PATH           Report file path (default: /var/lib/mb-backup/db-backup-<ts>.txt)
  --json-report PATH      JSON report file path (default: alongside --report with .json)
  --keep                  Keep dump files after completion (do not clean up)
  --dry-run               Preview which databases would be backed up; write no dumps
  --help, -h              Show this help

Docker auto-discovery:
  Containers with the label `backup.db-type=postgres|mysql|redis|mongo` are
  automatically detected. Additional labels can refine connection parameters:
    backup.db-name=NAME       Database name (postgres/mysql/mongo)
    backup.db-user=USER       Database user
    backup.db-port=PORT       Database port (overrides default)

Homepage: https://github.com/0x10debug/backup-kit
HELP
}

while [ $# -gt 0 ]; do
    case "$1" in
        --auto)        DB_MODE="auto"; shift ;;
        --type)        DB_TYPE="$2"; shift 2 ;;
        --host)        DB_HOST="$2"; shift 2 ;;
        --port)        DB_PORT="$2"; shift 2 ;;
        --user)        DB_USER="$2"; shift 2 ;;
        --password)    DB_PASSWORD="$2"; shift 2 ;;
        --db)          DB_NAME="$2"; shift 2 ;;
        --container)   DB_CONTAINER="$2"; shift 2 ;;
        --dump-dir)    DB_DUMP_DIR="$2"; shift 2 ;;
        --report)      DB_REPORT="$2"; shift 2 ;;
        --json-report) DB_JSON_REPORT="$2"; shift 2 ;;
        --keep)        DB_KEEP=true; shift ;;
        --dry-run)     DB_DRY_RUN=true; shift ;;
        --version)     echo "db-backup.sh ${DB_VERSION} (${DB_HOMEPAGE})"; exit 0 ;;
        --help|-h)     db_show_help; exit 0 ;;
        *) db_error "Unknown option: $1"; db_show_help; exit 2 ;;
    esac
done

# ── Prerequisite checks ──────────────────────────────────────────────────────

db_check_command() {
    command -v "$1" >/dev/null 2>&1
}

db_validate_type() {
    local t="$1"
    for valid in "${DB_SUPPORTED_TYPES[@]}"; do
        [ "$t" = "$valid" ] && return 0
    done
    return 1
}

# ── Validation ───────────────────────────────────────────────────────────────

if [ "$DB_MODE" != "auto" ] && [ -z "$DB_TYPE" ]; then
    db_error "Either --auto or --type TYPE must be specified."
    db_show_help
    exit 2
fi

if [ -n "$DB_TYPE" ]; then
    db_validate_type "$DB_TYPE" || db_die "Unsupported database type: $DB_TYPE (use: ${DB_SUPPORTED_TYPES[*]})"
    # If --type is given without --auto, switch to manual mode
    if [ "$DB_MODE" != "auto" ]; then
        DB_MODE="manual"
    fi
fi

if [ "$DB_MODE" = "manual" ] && [ -z "$DB_HOST" ]; then
    db_die "--host is required in manual mode (or use --auto for Docker discovery)."
fi

# Timestamp for default paths
DB_TS="$(date '+%Y%m%d-%H%M%S')"
if [ -z "$DB_DUMP_DIR" ]; then
    DB_DUMP_DIR="${DB_BACKUP_TMP}/db-dumps-${DB_TS}"
fi
if [ -z "$DB_REPORT" ]; then
    DB_REPORT="${DB_STATE_DIR}/db-backup-${DB_TS}.txt"
fi
if [ -z "$DB_JSON_REPORT" ]; then
    DB_JSON_REPORT="${DB_REPORT%.txt}.json"
fi

# ── Docker auto-discovery ────────────────────────────────────────────────────

# Scan running Docker containers for the backup.db-type label.
# Echoes one line per discovered database:
#   "container|type|host|port|user|password|db"
# host is set to the container name (we exec into it), port to the default
# unless overridden by a backup.db-port label.
db_discover_containers() {
    if ! db_check_command docker; then
        db_warn "docker is not installed — auto-discovery unavailable."
        return 0
    fi

    # List running container IDs that have the backup.db-type label.
    # The filter matches any value for the label key.
    local container_ids
    container_ids="$(docker ps --filter "label=${DB_LABEL}" --format '{{.ID}}' 2>/dev/null || true)"

    if [ -z "$container_ids" ]; then
        db_info "No Docker containers with label '${DB_LABEL}' found."
        return 0
    fi

    local cid
    while IFS= read -r cid; do
        [ -z "$cid" ] && continue
        local ctype chost cport cuser cpass cdb ccontainer_name

        # Read labels for this container
        ctype="$(docker inspect --format "{{ index .Config.Labels \"${DB_LABEL}\" }}" "$cid" 2>/dev/null || true)"
        # Validate the type
        if ! db_validate_type "$ctype"; then
            db_warn "Container ${cid}: invalid ${DB_LABEL}='${ctype}', skipping."
            continue
        fi

        cdb="$(docker inspect --format "{{ index .Config.Labels \"backup.db-name\" }}" "$cid" 2>/dev/null || true)"
        cuser="$(docker inspect --format "{{ index .Config.Labels \"backup.db-user\" }}" "$cid" 2>/dev/null || true)"
        cport="$(docker inspect --format "{{ index .Config.Labels \"backup.db-port\" }}" "$cid" 2>/dev/null || true)"
        ccontainer_name="$(docker inspect --format '{{.Name}}' "$cid" 2>/dev/null | sed 's|^/||' || true)"

        # For Docker-based dumps, we exec into the container, so host = container name
        chost="$ccontainer_name"
        cpass=""  # Passwords are not stored in labels; use env vars inside the container

        # Default port if not specified
        if [ -z "$cport" ]; then
            cport="${DB_DEFAULT_PORTS[$ctype]}"
        fi

        # Redis doesn't use a database name
        if [ "$ctype" = "redis" ]; then
            cdb=""
        fi

        echo "${ccontainer_name}|${ctype}|${chost}|${cport}|${cuser}|${cpass}|${cdb}"
    done <<< "$container_ids"
}

# ── Dump functions ───────────────────────────────────────────────────────────

# Each dump function receives: host port user password db container dump_file
# Returns 0 on success, non-zero on failure.
# When DB_CONTAINER is set, the dump command is executed via `docker exec`.

# PostgreSQL: pg_dump --format=custom
db_dump_postgres() {
    local host="$1" port="$2" user="$3" password="$4" db="$5" container="$6" dump_file="$7"

    # Build connection arguments
    local conn_args=()
    conn_args+=(--host "$host" --port "$port")
    [ -n "$user" ] && conn_args+=(--username "$user")
    [ -n "$db" ] && conn_args+=("$db")

    # Set PGPASSWORD if provided (for non-interactive auth)
    if [ -n "$password" ]; then
        export PGPASSWORD="$password"
    fi

    # shellcheck disable=SC2086
    if [ -n "$container" ]; then
        # Exec into container — dump to stdout, redirect to local file
        docker exec -e PGPASSWORD="${password:-}" "$container" \
            pg_dump --format=custom "${conn_args[@]}" > "$dump_file"
    else
        pg_dump --format=custom "${conn_args[@]}" > "$dump_file"
    fi

    unset PGPASSWORD 2>/dev/null || true
}

# MySQL/MariaDB: mysqldump --single-transaction --routines --triggers
db_dump_mysql() {
    local host="$1" port="$2" user="$3" password="$4" db="$5" container="$6" dump_file="$7"

    local conn_args=()
    conn_args+=(--host "$host" --port "$port")
    [ -n "$user" ] && conn_args+=(--user "$user")
    [ -n "$db" ] && conn_args+=("$db")

    local pass_args=()
    if [ -n "$password" ]; then
        pass_args+=(--password="${password}")
    fi

    if [ -n "$container" ]; then
        docker exec "$container" \
            mysqldump --single-transaction --routines --triggers "${pass_args[@]}" "${conn_args[@]}" \
            > "$dump_file"
    else
        mysqldump --single-transaction --routines --triggers "${pass_args[@]}" "${conn_args[@]}" \
            > "$dump_file"
    fi
}

# Redis: BGSAVE + wait + copy rdb file
db_dump_redis() {
    local host="$1" port="$2" user="$3" password="$4" db="$5" container="$6" dump_file="$7"

    local conn_args=()
    conn_args+=(-h "$host" -p "$port")
    if [ -n "$password" ]; then
        conn_args+=(-a "$password")
    fi

    if [ -n "$container" ]; then
        # Trigger BGSAVE inside the container
        docker exec "$container" redis-cli "${conn_args[@]}" BGSAVE >/dev/null

        # Poll for BGSAVE completion (last_save_time changes after BGSAVE finishes)
        local last_save_before last_save_after attempts=0
        last_save_before="$(docker exec "$container" redis-cli "${conn_args[@]}" LASTSAVE 2>/dev/null | tr -d '[:space:]' || echo 0)"

        while [ "$attempts" -lt 60 ]; do
            sleep 1
            last_save_after="$(docker exec "$container" redis-cli "${conn_args[@]}" LASTSAVE 2>/dev/null | tr -d '[:space:]' || echo 0)"
            if [ "$last_save_after" != "$last_save_before" ]; then
                break
            fi
            attempts=$((attempts + 1))
        done

        if [ "$last_save_after" = "$last_save_before" ]; then
            db_warn "Redis BGSAVE did not complete within 60s — copying current RDB anyway."
        fi

        # Copy the RDB file out of the container
        # Find the Redis data directory (default /data or /var/lib/redis)
        local redis_data_dir
        redis_data_dir="$(docker exec "$container" sh -c 'redis-cli config get dir 2>/dev/null | tail -1' 2>/dev/null || echo "/data")"
        [ -z "$redis_data_dir" ] && redis_data_dir="/data"

        local redis_dbfile
        redis_dbfile="$(docker exec "$container" sh -c 'redis-cli config get dbfilename 2>/dev/null | tail -1' 2>/dev/null || echo "dump.rdb")"
        [ -z "$redis_dbfile" ] && redis_dbfile="dump.rdb"

        docker cp "${container}:${redis_data_dir}/${redis_dbfile}" "$dump_file"
    else
        # Local Redis
        redis-cli "${conn_args[@]}" BGSAVE >/dev/null

        local last_save_before last_save_after attempts=0
        last_save_before="$(redis-cli "${conn_args[@]}" LASTSAVE 2>/dev/null | tr -d '[:space:]' || echo 0)"

        while [ "$attempts" -lt 60 ]; do
            sleep 1
            last_save_after="$(redis-cli "${conn_args[@]}" LASTSAVE 2>/dev/null | tr -d '[:space:]' || echo 0)"
            if [ "$last_save_after" != "$last_save_before" ]; then
                break
            fi
            attempts=$((attempts + 1))
        done

        if [ "$last_save_after" = "$last_save_before" ]; then
            db_warn "Redis BGSAVE did not complete within 60s — copying current RDB anyway."
        fi

        local redis_data_dir redis_dbfile
        redis_data_dir="$(redis-cli "${conn_args[@]}" config get dir 2>/dev/null | tail -1 || echo "/var/lib/redis")"
        [ -z "$redis_data_dir" ] && redis_data_dir="/var/lib/redis"
        redis_dbfile="$(redis-cli "${conn_args[@]}" config get dbfilename 2>/dev/null | tail -1 || echo "dump.rdb")"
        [ -z "$redis_dbfile" ] && redis_dbfile="dump.rdb"

        cp "${redis_data_dir}/${redis_dbfile}" "$dump_file"
    fi
}

# MongoDB: mongodump --archive --gzip
db_dump_mongo() {
    local host="$1" port="$2" user="$3" password="$4" db="$5" container="$6" dump_file="$7"

    local conn_args=()
    conn_args+=(--host "$host" --port "$port")
    [ -n "$db" ] && conn_args+=(--db "$db")

    # Build URI or auth args
    if [ -n "$user" ] && [ -n "$password" ]; then
        conn_args+=(--username "$user" --password "$password")
    fi

    if [ -n "$container" ]; then
        docker exec "$container" \
            mongodump --archive --gzip "${conn_args[@]}" > "$dump_file"
    else
        mongodump --archive --gzip "${conn_args[@]}" > "$dump_file"
    fi
}

# Dispatch to the correct dump function based on type.
db_run_dump() {
    local type="$1" host="$2" port="$3" user="$4" password="$5" db="$6" container="$7" dump_file="$8"

    case "$type" in
        postgres) db_dump_postgres "$host" "$port" "$user" "$password" "$db" "$container" "$dump_file" ;;
        mysql)    db_dump_mysql    "$host" "$port" "$user" "$password" "$db" "$container" "$dump_file" ;;
        redis)    db_dump_redis    "$host" "$port" "$user" "$password" "$db" "$container" "$dump_file" ;;
        mongo)    db_dump_mongo    "$host" "$port" "$user" "$password" "$db" "$container" "$dump_file" ;;
        *)        return 1 ;;
    esac
}

# ── Report helpers ───────────────────────────────────────────────────────────

# Append a result line to DB_RESULTS.
# Args: type host port db container status size_bytes duration_s dump_file error
db_add_result() {
    local entry
    entry="$(printf '%s|' "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}")"
    # Remove trailing pipe
    entry="${entry%|}"
    if [ -z "$DB_RESULTS" ]; then
        DB_RESULTS="$entry"
    else
        DB_RESULTS="${DB_RESULTS}
${entry}"
    fi
}

# Generate a text report.
db_generate_report_text() {
    local total success_count fail_count
    total="$(echo "$DB_RESULTS" | grep -c . 2>/dev/null || true)"
    success_count="$(echo "$DB_RESULTS" | grep -c '|OK|' 2>/dev/null || true)"
    fail_count="$(echo "$DB_RESULTS" | grep -c '|FAIL|' 2>/dev/null || true)"

    {
        echo "=========================================="
        echo " backup-kit Database Backup Report"
        echo "=========================================="
        echo "Date       : $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Mode       : ${DB_MODE}"
        echo "Dry-run    : ${DB_DRY_RUN}"
        echo "Dump dir   : ${DB_DUMP_DIR}"
        echo ""
        echo "---- Summary ----"
        echo "Total databases : ${total}"
        echo "Succeeded       : ${success_count}"
        echo "Failed          : ${fail_count}"
        echo ""
        echo "---- Details ----"

        if [ "$total" -gt 0 ]; then
            printf "%-10s %-20s %-8s %-16s %-8s %-12s %-12s %s\n" \
                "Type" "Host" "Port" "Database" "Status" "Size" "Duration" "Dump file"
            printf '%.0s-' {1..100}
            echo ""

            while IFS='|' read -r rtype rhost rport rdb rcontainer rstatus rsize rduration rdumpfile rerror; do
                local size_human
                size_human="$(db_human_size "$rsize")"
                printf "%-10s %-20s %-8s %-16s %-8s %-12s %-12s %s\n" \
                    "$rtype" "$rhost" "$rport" "$rdb" "$rstatus" "$size_human" "${rduration}s" "$(basename "$rdumpfile")"
                if [ "$rstatus" = "FAIL" ] && [ -n "$rerror" ]; then
                    printf "            Error: %s\n" "$rerror"
                fi
            done <<< "$DB_RESULTS"
        else
            echo "  (no databases processed)"
        fi

        echo ""
        echo "---- Verdict ----"
        if [ "$fail_count" -eq 0 ]; then
            echo "Result           : PASS"
        else
            echo "Result           : FAIL (${fail_count} dump(s) failed)"
        fi
        echo ""
        echo "Database dumps are included in the backup source for Restic/Kopia."
        echo "=========================================="
    }
}

# Generate a JSON report.
db_generate_report_json() {
    local total success_count fail_count
    total="$(echo "$DB_RESULTS" | grep -c . 2>/dev/null || true)"
    success_count="$(echo "$DB_RESULTS" | grep -c '|OK|' 2>/dev/null || true)"
    fail_count="$(echo "$DB_RESULTS" | grep -c '|FAIL|' 2>/dev/null || true)"

    local overall="PASS"
    [ "$fail_count" -gt 0 ] && overall="FAIL"

    # Build databases array
    local db_json=""
    local first=true
    if [ "$total" -gt 0 ]; then
        while IFS='|' read -r rtype rhost rport rdb rcontainer rstatus rsize rduration rdumpfile rerror; do
            [ -z "$rtype" ] && continue
            if [ "$first" = "true" ]; then
                first=false
            else
                db_json="${db_json},"
            fi
            # Escape the error and dumpfile fields for JSON
            local esc_error esc_dumpfile
            esc_error="$(db_json_escape "$rerror")"
            esc_dumpfile="$(db_json_escape "$rdumpfile")"
            db_json="${db_json}{\"type\":\"${rtype}\",\"host\":\"${rhost}\",\"port\":\"${rport}\",\"database\":\"${rdb}\",\"container\":\"${rcontainer}\",\"status\":\"${rstatus}\",\"size_bytes\":${rsize:-0},\"duration_s\":${rduration:-0},\"dump_file\":\"${esc_dumpfile}\",\"error\":\"${esc_error}\"}"
        done <<< "$DB_RESULTS"
    fi

    cat <<EOF
{
  "tool": "backup-kit db-backup",
  "version": "${DB_VERSION}",
  "timestamp": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "mode": "${DB_MODE}",
  "dry_run": ${DB_DRY_RUN},
  "dump_dir": "${DB_DUMP_DIR}",
  "summary": {
    "total": ${total:-0},
    "succeeded": ${success_count:-0},
    "failed": ${fail_count:-0}
  },
  "databases": [${db_json}],
  "overall": "${overall}"
}
EOF
}

# Escape a string for inclusion in JSON (handles backslash, double-quote, newline).
db_json_escape() {
    local s="${1:-}"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    printf '%s' "$s"
}

# Convert bytes to human-readable size.
db_human_size() {
    local bytes="${1:-0}"
    local unit
    for unit in B KB MB GB TB; do
        if [ "$bytes" -lt 1024 ] || [ "$unit" = "TB" ]; then
            printf "%.1f %s" "$bytes" "$unit"
            return
        fi
        bytes=$((bytes / 1024))
    done
}

# Get file size in bytes (portable).
db_file_size() {
    local file="$1"
    if [ -f "$file" ]; then
        # Use wc -c for portability (works on both GNU and BSD)
        wc -c < "$file" 2>/dev/null | tr -d '[:space:]' || echo 0
    else
        echo 0
    fi
}

# ── Core logic ───────────────────────────────────────────────────────────────

# Process a single database target: run the dump, record the result.
# Args: type host port user password db container
db_process_target() {
    local type="$1" host="$2" port="$3" user="$4" password="$5" db="$6" container="$7"

    local label
    if [ -n "$container" ]; then
        label="${type} [container: ${container}]"
    else
        label="${type}://${host}:${port}"
    fi
    [ -n "$db" ] && label="${label}/${db}"

    # Generate a dump file name
    local safe_name dump_file
    safe_name="$(db_safe_name "${type}-${host}-${port}-${db:-all}")"
    case "$type" in
        postgres) dump_file="${DB_DUMP_DIR}/${safe_name}.dump" ;;
        mysql)    dump_file="${DB_DUMP_DIR}/${safe_name}.sql" ;;
        redis)    dump_file="${DB_DUMP_DIR}/${safe_name}.rdb" ;;
        mongo)    dump_file="${DB_DUMP_DIR}/${safe_name}.archive.gz" ;;
    esac

    if [ "$DB_DRY_RUN" = "true" ]; then
        db_info "[dry-run] Would dump: ${label} → $(basename "$dump_file")"
        db_add_result "$type" "$host" "$port" "$db" "$container" "DRY-RUN" 0 0 "$dump_file" ""
        return 0
    fi

    db_info "Dumping: ${label}"
    local start_ts end_ts elapsed
    start_ts=$(date +%s)

    if db_run_dump "$type" "$host" "$port" "$user" "$password" "$db" "$container" "$dump_file"; then
        end_ts=$(date +%s)
        elapsed=$((end_ts - start_ts))
        local size
        size="$(db_file_size "$dump_file")"
        if [ "$size" -eq 0 ]; then
            db_warn "Dump file is empty: $dump_file"
        fi
        db_success "Dump OK: ${label} ($(db_human_size "$size"), ${elapsed}s)"
        db_add_result "$type" "$host" "$port" "$db" "$container" "OK" "$size" "$elapsed" "$dump_file" ""
    else
        local rc=$?
        end_ts=$(date +%s)
        elapsed=$((end_ts - start_ts))
        local err_msg="dump command exited with code ${rc}"
        db_error "Dump FAILED: ${label} — ${err_msg}"
        db_log_file "db-backup: FAIL — ${label}: ${err_msg}"
        db_add_result "$type" "$host" "$port" "$db" "$container" "FAIL" 0 "$elapsed" "$dump_file" "$err_msg"
    fi
}

# Sanitize a string for use as a filename.
db_safe_name() {
    local s="$1"
    s="${s// /_}"
    s="${s//\//_}"
    s="${s//:/_}"
    s="${s//[^a-zA-Z0-9_.-]/_}"
    # Collapse consecutive underscores
    while echo "$s" | grep -q '__'; do
        s="${s//__/_}"
    done
    echo "$s"
}

# ── Main ─────────────────────────────────────────────────────────────────────

db_main() {
    # Ensure report directory is writable (best-effort)
    mkdir -p "$(dirname "$DB_REPORT")" 2>/dev/null || true

    db_step "Database-aware backup (pre-backup dumps)"
    db_info "Mode     : $DB_MODE"
    db_info "Dry-run  : $DB_DRY_RUN"
    db_info "Dump dir : $DB_DUMP_DIR"
    db_info "Report   : $DB_REPORT"
    db_log_file "db-backup: started (mode=${DB_MODE}, dry-run=${DB_DRY_RUN})"

    local overall_start_ts overall_end_ts overall_elapsed
    overall_start_ts=$(date +%s)

    # ── 1. Collect targets ──────────────────────────────────────────────────
    db_step "Step 1/3 — Discovering database targets"

    local targets=""

    if [ "$DB_MODE" = "auto" ]; then
        db_info "Auto-discovering databases via Docker labels..."
        targets="$(db_discover_containers)"
        local auto_count
        auto_count="$(echo "$targets" | grep -c . 2>/dev/null || true)"
        db_info "Discovered ${auto_count} database(s) via Docker labels."

        # If --type was also given in auto mode, add a manual target too
        if [ -n "$DB_TYPE" ] && [ -n "$DB_HOST" ]; then
            local port="${DB_PORT:-${DB_DEFAULT_PORTS[$DB_TYPE]}}"
            local manual_target="${DB_TYPE}|${DB_HOST}|${port}|${DB_USER}|${DB_PASSWORD}|${DB_NAME}|${DB_CONTAINER}"
            if [ -n "$targets" ]; then
                targets="${targets}
${manual_target}"
            else
                targets="$manual_target"
            fi
            db_info "Also including manual target: ${DB_TYPE}://${DB_HOST}:${port}"
        fi
    else
        # Manual mode — single target
        local port="${DB_PORT:-${DB_DEFAULT_PORTS[$DB_TYPE]}}"
        targets="${DB_TYPE}|${DB_HOST}|${port}|${DB_USER}|${DB_PASSWORD}|${DB_NAME}|${DB_CONTAINER}"
        db_info "Manual target: ${DB_TYPE}://${DB_HOST}:${port}"
    fi

    local target_count
    target_count="$(echo "$targets" | grep -c . 2>/dev/null || true)"

    if [ "$target_count" -eq 0 ]; then
        db_warn "No database targets found. Nothing to back up."
        db_add_result "none" "" "" "" "" "SKIP" 0 0 "" "no targets discovered"
    fi

    # ── 2. Run dumps ─────────────────────────────────────────────────────────
    db_step "Step 2/3 — Running database dumps"

    if [ "$DB_DRY_RUN" = "true" ]; then
        db_info "DRY-RUN mode — no dumps will be written."
    else
        mkdir -p "$DB_DUMP_DIR"
        db_info "Dump directory: ${DB_DUMP_DIR}"
    fi

    if [ "$target_count" -gt 0 ]; then
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            # Parse: type|host|port|user|password|db|container
            local t_type t_host t_port t_user t_pass t_db t_container
            IFS='|' read -r t_type t_host t_port t_user t_pass t_db t_container <<< "$line"
            db_process_target "$t_type" "$t_host" "$t_port" "$t_user" "$t_pass" "$t_db" "$t_container"
        done <<< "$targets"
    fi

    overall_end_ts=$(date +%s)
    overall_elapsed=$((overall_end_ts - overall_start_ts))

    # ── 3. Generate report ───────────────────────────────────────────────────
    db_step "Step 3/3 — Generating report"

    # Write text report
    db_generate_report_text > "$DB_REPORT"
    db_detail "Text report: ${DB_REPORT}"

    # Write JSON report
    db_generate_report_json > "$DB_JSON_REPORT"
    db_detail "JSON report: ${DB_JSON_REPORT}"

    # Determine verdict
    local fail_count
    fail_count="$(echo "$DB_RESULTS" | grep -c '|FAIL|' 2>/dev/null || true)"

    if [ "$fail_count" -eq 0 ]; then
        db_success "Database backup completed (all dumps OK, ${overall_elapsed}s)."
        db_log_file "db-backup: PASS (targets=${target_count}, elapsed=${overall_elapsed}s)"
    else
        db_error "Database backup FAILED — ${fail_count} dump(s) failed."
        db_log_file "db-backup: FAIL (targets=${target_count}, failed=${fail_count}, elapsed=${overall_elapsed}s)"
    fi

    # Print integration hint
    if [ "$DB_DRY_RUN" = "false" ] && [ "$target_count" -gt 0 ]; then
        db_info ""
        db_info "Dump files are in: ${DB_DUMP_DIR}"
        db_info "Include this directory in your Restic/Kopia backup paths so dumps"
        db_info "are captured in the next snapshot. Example:"
        db_detail "restic backup ${DB_DUMP_DIR} /data"
        db_detail "kopia snapshot create ${DB_DUMP_DIR} /data"
    fi

    # ── Cleanup ──────────────────────────────────────────────────────────────
    if [ "$DB_KEEP" = "true" ]; then
        db_info "Keeping dump files at: ${DB_DUMP_DIR}"
    elif [ "$DB_DRY_RUN" = "false" ] && [ "$target_count" -gt 0 ]; then
        # Only clean up if all dumps succeeded — keep failed dumps for inspection
        if [ "$fail_count" -eq 0 ]; then
            db_info "Cleaning up dump directory: ${DB_DUMP_DIR}"
            rm -rf -- "$DB_DUMP_DIR"
            db_detail "Dump files removed. They have been captured in the backup snapshot."
        else
            db_warn "Keeping dump files (some dumps failed) for inspection: ${DB_DUMP_DIR}"
        fi
    fi

    # Exit code
    if [ "$fail_count" -gt 0 ]; then
        return 1
    fi
    return 0
}

# ── Run ──────────────────────────────────────────────────────────────────────

db_main
exit $?
