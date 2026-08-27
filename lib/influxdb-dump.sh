#!/usr/bin/env bash
# lib/influxdb-dump.sh — InfluxDB-aware backup for backup-kit
#
# backup-kit: encrypted, automated, tested recovery for VPS and Docker.
# Homepage: https://github.com/0x10debug/backup-kit
#
# This library provides InfluxDB backup capabilities, supporting both
# InfluxDB 1.x (influx backup) and InfluxDB 2.x (influx backup).
# It can be sourced by volume-backup.sh or db-backup.sh, or run standalone.
#
# Targets can be discovered automatically by scanning running Docker
# containers for the label `backup.influxdb`, or specified manually.
#
# Usage (standalone):
#   influxdb-dump.sh [OPTIONS]
#
# Options:
#   --auto                    Auto-discover InfluxDB via Docker container labels
#   --host URL                InfluxDB host URL (e.g., http://localhost:8086)
#   --version-major VERSION   InfluxDB major version: 1|2 (default: auto-detect)
#   --database NAME           Database/bucket name to back up (1.x: database, 2.x: bucket)
#   --all                     Back up all databases/buckets
#   --token TOKEN             InfluxDB 2.x API token (or env INFLUX_TOKEN)
#   --org ORG                 InfluxDB 2.x organization (or env INFLUX_ORG)
#   --username USER           InfluxDB 1.x username (or env INFLUX_USERNAME)
#   --password PWD            InfluxDB 1.x password (or env INFLUX_PASSWORD)
#   --container NAME          Docker container running InfluxDB (exec into it)
#   --output-dir PATH         Output directory for backups (default: /backup/influxdb-backups-<ts>)
#   --dry-run                 Preview without writing backups
#   --help, -h                Show this help
#
# Exit codes:
#   0  All backups succeeded (or dry-run completed)
#   1  One or more backups failed
#   2  Invalid arguments / missing prerequisites

set -euo pipefail

# ── Constants ────────────────────────────────────────────────────────────────

readonly IF_VERSION="1.0.0"
readonly IF_HOMEPAGE="https://github.com/0x10debug/backup-kit"

readonly IF_SUPPORTED_VERSIONS=(1 2)

# Docker label used for auto-discovery
readonly IF_LABEL="backup.influxdb"

# ── Color variables ──────────────────────────────────────────────────────────

if [ -t 1 ]; then
    readonly IF_C_FAIL='\033[0;31m'
    readonly IF_C_OK='\033[0;32m'
    readonly IF_C_WARN='\033[0;33m'
    readonly IF_C_INFO='\033[0;34m'
    readonly IF_C_RST='\033[0m'
else
    readonly IF_C_FAIL=''
    readonly IF_C_OK=''
    readonly IF_C_WARN=''
    readonly IF_C_INFO=''
    readonly IF_C_RST=''
fi

# ── Defaults ─────────────────────────────────────────────────────────────────

IF_MODE=""              # "auto" or "manual"
IF_HOST=""
IF_VERSION_MAJOR=""
IF_DATABASE=""
IF_ALL=false
IF_TOKEN="${INFLUX_TOKEN:-}"
IF_ORG="${INFLUX_ORG:-}"
IF_USERNAME="${INFLUX_USERNAME:-}"
IF_PASSWORD="${INFLUX_PASSWORD:-}"
IF_CONTAINER=""
IF_OUTPUT_DIR=""
IF_DRY_RUN=false

# Resolved at runtime
IF_STATE_DIR="${MB_STATE_DIR:-/var/lib/mb-backup}"
IF_LOG_FILE="${MB_LOG_FILE:-/var/log/mb-backup.log}"
IF_BACKUP_TMP="${MB_BACKUP_TMP:-/backup}"

# Accumulated results
# Each entry: "instance|version|database|status|size_bytes|duration_s|backup_dir|error"
IF_RESULTS=""

# ── Logging helpers ──────────────────────────────────────────────────────────

if_log() {
    local level="$1"; shift
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    printf '[%s] %s %s\n' "$ts" "$level" "$*"
}

if_info()    { if_log "${IF_C_INFO}INFO${IF_C_RST}" "$*" >&2; }
if_success() { printf "${IF_C_OK}%s${IF_C_RST}\n" "$*" >&2; }
if_warn()    { printf "${IF_C_WARN}WARN: %s${IF_C_RST}\n" "$*" >&2; }
if_error()   { printf "${IF_C_FAIL}ERROR: %s${IF_C_RST}\n" "$*" >&2; }
if_step()    { printf '\n==> %s\n' "$*" >&2; }
if_detail()  { printf '    %s\n' "$*" >&2; }

if_log_file() {
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    ( mkdir -p "$(dirname "$IF_LOG_FILE")" 2>/dev/null
      echo "[${ts}] $*" >> "$IF_LOG_FILE" ) 2>/dev/null || true
}

if_die() {
    if_error "$*"
    if_log_file "influxdb-dump: FATAL: $*"
    exit 2
}

# ── Argument parsing ─────────────────────────────────────────────────────────

if_show_help() {
    cat <<'HELP'
influxdb-dump.sh — InfluxDB-aware backup

Backs up InfluxDB databases (1.x) or buckets (2.x) using the native
influx backup command. Supports Docker container auto-discovery and
manual mode.

Usage:
  influxdb-dump.sh --auto [OPTIONS]
  influxdb-dump.sh --host URL --database NAME [OPTIONS]
  influxdb-dump.sh --host URL --all [OPTIONS]

Options:
  --auto                    Auto-discover InfluxDB via Docker container labels
  --host URL                InfluxDB host URL (e.g., http://localhost:8086)
  --version-major VERSION   InfluxDB major version: 1|2 (default: auto-detect)
  --database NAME           Database (1.x) or bucket (2.x) name to back up
  --all                     Back up all databases/buckets
  --token TOKEN             InfluxDB 2.x API token (or env INFLUX_TOKEN)
  --org ORG                 InfluxDB 2.x organization (or env INFLUX_ORG)
  --username USER           InfluxDB 1.x username (or env INFLUX_USERNAME)
  --password PWD            InfluxDB 1.x password (or env INFLUX_PASSWORD)
  --container NAME          Docker container running InfluxDB (exec into it)
  --output-dir PATH         Output directory for backups (default: /backup/influxdb-backups-<ts>)
  --dry-run                 Preview without writing backups
  --help, -h                Show this help

Docker auto-discovery:
  Containers with the label `backup.influxdb` are automatically detected.
  The label value can be "1" or "2" to specify the major version.
  Additional labels:
    backup.influxdb-port=PORT    InfluxDB port (default: 8086)
    backup.influxdb-org=ORG      Organization (2.x)
    backup.influxdb-token=TOKEN  API token (2.x, not recommended in labels)

Version detection:
  If --version-major is not specified, the script tries to detect the
  version by calling the InfluxDB /health endpoint. InfluxDB 2.x returns
  a JSON with "version" field starting with "2"; 1.x returns a simpler
  response.

Homepage: https://github.com/0x10debug/backup-kit
HELP
}

# Parse arguments only when run standalone (not sourced)
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    while [ $# -gt 0 ]; do
        case "$1" in
            --auto)           IF_MODE="auto"; shift ;;
            --host)           IF_HOST="$2"; shift 2 ;;
            --version-major)  IF_VERSION_MAJOR="$2"; shift 2 ;;
            --database)       IF_DATABASE="$2"; shift 2 ;;
            --all)            IF_ALL=true; shift ;;
            --token)          IF_TOKEN="$2"; shift 2 ;;
            --org)            IF_ORG="$2"; shift 2 ;;
            --username)       IF_USERNAME="$2"; shift 2 ;;
            --password)       IF_PASSWORD="$2"; shift 2 ;;
            --container)      IF_CONTAINER="$2"; shift 2 ;;
            --output-dir)     IF_OUTPUT_DIR="$2"; shift 2 ;;
            --dry-run)        IF_DRY_RUN=true; shift ;;
            --version)        echo "influxdb-dump.sh ${IF_VERSION} (${IF_HOMEPAGE})"; exit 0 ;;
            --help|-h)        if_show_help; exit 0 ;;
            *) if_error "Unknown option: $1"; if_show_help; exit 2 ;;
        esac
    done
fi

# ── Prerequisite checks ──────────────────────────────────────────────────────

if_check_command() {
    command -v "$1" >/dev/null 2>&1
}

if_validate_version() {
    local v="$1"
    for valid in "${IF_SUPPORTED_VERSIONS[@]}"; do
        [ "$v" = "$valid" ] && return 0
    done
    return 1
}

# ── Utility functions ────────────────────────────────────────────────────────

if_safe_name() {
    local s="$1"
    s="${s// /_}"
    s="${s//\//_}"
    s="${s//:/_}"
    s="${s//[^a-zA-Z0-9_.-]/_}"
    while echo "$s" | grep -q '__'; do
        s="${s//__/_}"
    done
    echo "$s"
}

if_dir_size() {
    local dir="$1"
    if [ -d "$dir" ]; then
        du -sk "$dir" 2>/dev/null | awk '{print $1 * 1024}'
    else
        echo 0
    fi
}

if_human_size() {
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

if_json_escape() {
    local s="${1:-}"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    printf '%s' "$s"
}

# Auto-detect InfluxDB major version by querying /health endpoint.
# Args: host_url
# Echoes "1" or "2", or empty if detection fails.
if_detect_version() {
    local host="$1"
    if if_check_command curl; then
        local health
        health="$(curl -s "${host}/health" 2>/dev/null || true)"
        if echo "$health" | grep -q '"version"' ; then
            local ver
            ver="$(echo "$health" | grep -o '"version":"[^"]*"' | head -1 | cut -d'"' -f4)"
            case "$ver" in
                2*) echo "2" ;;
                1*) echo "1" ;;
                *)  echo "" ;;
            esac
        elif [ -n "$health" ]; then
            # InfluxDB 1.x /ping returns 204 with no body, /health may not exist
            # Try /ping
            local ping_status
            ping_status="$(curl -s -o /dev/null -w '%{http_code}' "${host}/ping" 2>/dev/null || true)"
            if [ "$ping_status" = "204" ]; then
                echo "1"
            else
                echo ""
            fi
        else
            echo ""
        fi
    else
        echo ""
    fi
}

# ── Docker auto-discovery ────────────────────────────────────────────────────

# Scan running Docker containers for the backup.influxdb label.
# Echoes one line per discovered instance:
#   "container|host|port|version|org|token|username|password"
if_discover_instances() {
    if ! if_check_command docker; then
        if_warn "docker is not installed — auto-discovery unavailable."
        return 0
    fi

    local container_ids
    container_ids="$(docker ps --filter "label=${IF_LABEL}" --format '{{.ID}}' 2>/dev/null || true)"

    if [ -z "$container_ids" ]; then
        if_info "No Docker containers with label '${IF_LABEL}' found."
        return 0
    fi

    local cid
    while IFS= read -r cid; do
        [ -z "$cid" ] && continue
        local cversion cport corg ctoken cuser cpass ccontainer_name chost

        cversion="$(docker inspect --format "{{ index .Config.Labels \"${IF_LABEL}\" }}" "$cid" 2>/dev/null || true)"
        cport="$(docker inspect --format "{{ index .Config.Labels \"backup.influxdb-port\" }}" "$cid" 2>/dev/null || true)"
        corg="$(docker inspect --format "{{ index .Config.Labels \"backup.influxdb-org\" }}" "$cid" 2>/dev/null || true)"
        ctoken="$(docker inspect --format "{{ index .Config.Labels \"backup.influxdb-token\" }}" "$cid" 2>/dev/null || true)"
        ccontainer_name="$(docker inspect --format '{{.Name}}' "$cid" 2>/dev/null | sed 's|^/||' || true)"

        [ -z "$cport" ] && cport="8086"
        [ -z "$cversion" ] && cversion=""
        [ -z "$corg" ] && corg="$IF_ORG"
        [ -z "$ctoken" ] && ctoken="$IF_TOKEN"

        chost="http://localhost:${cport}"
        cuser="$IF_USERNAME"
        cpass="$IF_PASSWORD"

        echo "${ccontainer_name}|${chost}|${cport}|${cversion}|${corg}|${ctoken}|${cuser}|${cpass}"
    done <<< "$container_ids"
}

# ── Backup methods ───────────────────────────────────────────────────────────

# Back up InfluxDB 1.x using `influx backup` (or `influxd backup`).
# Args: host database output_dir [username] [password]
if_backup_v1() {
    local host="$1" database="$2" out_dir="$3" username="$4" password="$5"
    local backup_path
    backup_path="${out_dir}/$(if_safe_name "$database")"
    mkdir -p "$backup_path"

    local backup_cmd=(influx backup)
    [ -n "$username" ] && backup_cmd+=(-username "$username")
    [ -n "$password" ] && backup_cmd+=(-password "$password")
    backup_cmd+=(-host "$host" -database "$database" "$backup_path")

    # Some 1.x versions use `influxd backup` instead of `influx backup`
    if ! if_check_command influx; then
        if if_check_command influxd; then
            backup_cmd=(influxd backup)
            [ -n "$username" ] && backup_cmd+=(-username "$username")
            [ -n "$password" ] && backup_cmd+=(-password "$password")
            backup_cmd+=(-host "$host" -database "$database" "$backup_path")
        else
            if_error "Neither 'influx' nor 'influxd' command is installed."
            return 1
        fi
    fi

    "${backup_cmd[@]}" 2>&1 >&2
}

# Back up InfluxDB 2.x using `influx backup`.
# Args: host bucket output_dir token org
if_backup_v2() {
    local host="$1" bucket="$2" out_dir="$3" token="$4" org="$5"
    local backup_path
    backup_path="${out_dir}/$(if_safe_name "$bucket")"
    mkdir -p "$backup_path"

    if ! if_check_command influx; then
        if_error "influx CLI is not installed (required for 2.x backup)."
        return 1
    fi

    [ -z "$token" ] && { if_error "InfluxDB 2.x requires --token or INFLUX_TOKEN env var."; return 1; }
    [ -z "$org" ] && { if_error "InfluxDB 2.x requires --org or INFLUX_ORG env var."; return 1; }

    influx backup \
        --host "$host" \
        --token "$token" \
        --org "$org" \
        --bucket "$bucket" \
        "$backup_path" 2>&1 >&2
}

# ── Report helpers ───────────────────────────────────────────────────────────

if_add_result() {
    local entry
    entry="$(printf '%s|' "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8")"
    entry="${entry%|}"
    if [ -z "$IF_RESULTS" ]; then
        IF_RESULTS="$entry"
    else
        IF_RESULTS="${IF_RESULTS}
${entry}"
    fi
}

if_generate_report_text() {
    local total success_count fail_count
    total="$(echo "$IF_RESULTS" | grep -c . 2>/dev/null || true)"
    success_count="$(echo "$IF_RESULTS" | grep -c '|OK|' 2>/dev/null || true)"
    fail_count="$(echo "$IF_RESULTS" | grep -c '|FAIL|' 2>/dev/null || true)"

    {
        echo "=========================================="
        echo " backup-kit InfluxDB Backup Report"
        echo "=========================================="
        echo "Date       : $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Mode       : ${IF_MODE}"
        echo "Dry-run    : ${IF_DRY_RUN}"
        echo "Output dir : ${IF_OUTPUT_DIR}"
        echo ""
        echo "---- Summary ----"
        echo "Total databases : ${total}"
        echo "Succeeded       : ${success_count}"
        echo "Failed          : ${fail_count}"
        echo ""
        echo "---- Details ----"

        if [ "$total" -gt 0 ]; then
            printf "%-20s %-8s %-25s %-8s %-12s %-10s %s\n" \
                "Instance" "Version" "Database/Bucket" "Status" "Size" "Duration" "Path"
            printf '%.0s-' {1..110}
            echo ""

            while IFS='|' read -r rinstance rversion rdatabase rstatus rsize rduration rbackupdir rerror; do
                local size_human
                size_human="$(if_human_size "$rsize")"
                printf "%-20s %-8s %-25s %-8s %-12s %-10s %s\n" \
                    "$rinstance" "v${rversion}" "$rdatabase" "$rstatus" "$size_human" "${rduration}s" "$(basename "$rbackupdir")"
                if [ "$rstatus" = "FAIL" ] && [ -n "$rerror" ]; then
                    printf "                    Error: %s\n" "$rerror"
                fi
            done <<< "$IF_RESULTS"
        else
            echo "  (no databases processed)"
        fi

        echo ""
        echo "---- Verdict ----"
        if [ "$fail_count" -eq 0 ]; then
            echo "Result           : PASS"
        else
            echo "Result           : FAIL (${fail_count} database(s) failed)"
        fi
        echo "=========================================="
    }
}

if_generate_report_json() {
    local total success_count fail_count
    total="$(echo "$IF_RESULTS" | grep -c . 2>/dev/null || true)"
    success_count="$(echo "$IF_RESULTS" | grep -c '|OK|' 2>/dev/null || true)"
    fail_count="$(echo "$IF_RESULTS" | grep -c '|FAIL|' 2>/dev/null || true)"

    local overall="PASS"
    [ "$fail_count" -gt 0 ] && overall="FAIL"

    local db_json=""
    local first=true
    if [ "$total" -gt 0 ]; then
        while IFS='|' read -r rinstance rversion rdatabase rstatus rsize rduration rbackupdir rerror; do
            [ -z "$rinstance" ] && continue
            if [ "$first" = "true" ]; then
                first=false
            else
                db_json="${db_json},"
            fi
            local esc_dir esc_error
            esc_dir="$(if_json_escape "$rbackupdir")"
            esc_error="$(if_json_escape "$rerror")"
            db_json="${db_json}{\"instance\":\"${rinstance}\",\"version\":\"${rversion}\",\"database\":\"${rdatabase}\",\"status\":\"${rstatus}\",\"size_bytes\":${rsize:-0},\"duration_s\":${rduration:-0},\"backup_dir\":\"${esc_dir}\",\"error\":\"${esc_error}\"}"
        done <<< "$IF_RESULTS"
    fi

    cat <<EOF
{
  "tool": "backup-kit influxdb-dump",
  "version": "${IF_VERSION}",
  "timestamp": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "mode": "${IF_MODE}",
  "dry_run": ${IF_DRY_RUN},
  "output_dir": "${IF_OUTPUT_DIR}",
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

# ── Core logic ───────────────────────────────────────────────────────────────

# Process a single database/bucket backup.
# Args: instance host version database token org username password
if_process_database() {
    local instance="$1" host="$2" version="$3" database="$4"
    local token="$5" org="$6" username="$7" password="$8"
    local label="${instance}/v${version}/${database}"

    if [ "$IF_DRY_RUN" = "true" ]; then
        if_info "[dry-run] Would back up: ${label}"
        if_add_result "$instance" "$version" "$database" "DRY-RUN" 0 0 "" ""
        return 0
    fi

    if_info "Backing up: ${label}"
    local start_ts end_ts elapsed
    start_ts=$(date +%s)

    local rc=0
    if [ "$version" = "2" ]; then
        if_backup_v2 "$host" "$database" "$IF_OUTPUT_DIR" "$token" "$org" || rc=$?
    else
        if_backup_v1 "$host" "$database" "$IF_OUTPUT_DIR" "$username" "$password" || rc=$?
    fi

    end_ts=$(date +%s)
    elapsed=$((end_ts - start_ts))

    if [ "$rc" -eq 0 ]; then
        local backup_path size
        backup_path="${IF_OUTPUT_DIR}/$(if_safe_name "$database")"
        size="$(if_dir_size "$backup_path")"
        if_success "Backup OK: ${label} ($(if_human_size "$size"), ${elapsed}s)"
        if_add_result "$instance" "$version" "$database" "OK" "$size" "$elapsed" "$backup_path" ""
    else
        local err_msg="influx backup exited with code ${rc}"
        if_error "Backup FAILED: ${label} — ${err_msg}"
        if_log_file "influxdb-dump: FAIL — ${label}: ${err_msg}"
        if_add_result "$instance" "$version" "$database" "FAIL" 0 "$elapsed" "" "$err_msg"
    fi
}

# ── Main (standalone mode) ───────────────────────────────────────────────────

if_main() {
    # Validation
    if [ "$IF_MODE" != "auto" ] && [ -z "$IF_HOST" ]; then
        if_error "Either --auto or --host URL must be specified."
        if_show_help
        exit 2
    fi

    if [ -n "$IF_HOST" ] && [ "$IF_MODE" != "auto" ]; then
        IF_MODE="manual"
    fi

    if [ -n "$IF_DATABASE" ] && [ "$IF_ALL" = "true" ]; then
        if_die "--database and --all are mutually exclusive."
    fi

    if [ -z "$IF_DATABASE" ] && [ "$IF_ALL" = "false" ]; then
        IF_ALL=true
        if_info "No --database specified, defaulting to --all."
    fi

    if [ -n "$IF_VERSION_MAJOR" ]; then
        if_validate_version "$IF_VERSION_MAJOR" || if_die "Unsupported version: $IF_VERSION_MAJOR (use: ${IF_SUPPORTED_VERSIONS[*]})"
    fi

    # Timestamp for default paths
    local ts
    ts="$(date '+%Y%m%d-%H%M%S')"
    if [ -z "$IF_OUTPUT_DIR" ]; then
        IF_OUTPUT_DIR="${IF_BACKUP_TMP}/influxdb-backups-${ts}"
    fi

    local report="${IF_STATE_DIR}/influxdb-dump-${ts}.txt"
    local json_report="${report%.txt}.json"
    mkdir -p "$(dirname "$report")" 2>/dev/null || true

    if_step "InfluxDB-aware backup"
    if_info "Mode     : $IF_MODE"
    if_info "Dry-run  : $IF_DRY_RUN"
    if_info "Output   : $IF_OUTPUT_DIR"
    if_log_file "influxdb-dump: started (mode=${IF_MODE}, dry-run=${IF_DRY_RUN})"

    local overall_start_ts overall_end_ts overall_elapsed
    overall_start_ts=$(date +%s)

    # ── 1. Collect targets ──────────────────────────────────────────────────
    if_step "Step 1/3 — Discovering InfluxDB targets"

    local instances=""
    if [ "$IF_MODE" = "auto" ]; then
        if_info "Auto-discovering InfluxDB via Docker labels..."
        instances="$(if_discover_instances)"
        local auto_count
        auto_count="$(echo "$instances" | grep -c . 2>/dev/null || true)"
        if_info "Discovered ${auto_count} InfluxDB instance(s) via Docker labels."
    else
        instances="${IF_CONTAINER:-manual}|${IF_HOST}|8086|${IF_VERSION_MAJOR}|${IF_ORG}|${IF_TOKEN}|${IF_USERNAME}|${IF_PASSWORD}"
    fi

    # ── 2. Run backups ───────────────────────────────────────────────────────
    if_step "Step 2/3 — Running InfluxDB backups"

    if [ "$IF_DRY_RUN" = "false" ]; then
        mkdir -p "$IF_OUTPUT_DIR"
        if_info "Output directory: ${IF_OUTPUT_DIR}"
    else
        if_info "DRY-RUN mode — no backups will be written."
    fi

    local inst_line
    while IFS= read -r inst_line; do
        [ -z "$inst_line" ] && continue
        local i_container i_host i_port i_version i_org i_token i_user i_pass
        IFS='|' read -r i_container i_host i_port i_version i_org i_token i_user i_pass <<< "$inst_line"

        # Log instance details (i_port is part of the host URL already)
        if_detail "Instance: ${i_container} (port: ${i_port}, version: ${i_version:-auto})"

        # Auto-detect version if not specified
        if [ -z "$i_version" ]; then
            if [ "$IF_DRY_RUN" = "true" ]; then
                i_version="${IF_VERSION_MAJOR:-2}"
                if_info "[dry-run] Assuming version ${i_version} (auto-detect skipped in dry-run)."
            else
                i_version="$(if_detect_version "$i_host")"
                if [ -z "$i_version" ]; then
                    i_version="${IF_VERSION_MAJOR:-2}"
                    if_warn "Could not auto-detect version at ${i_host}, assuming ${i_version}."
                else
                    if_info "Detected InfluxDB v${i_version} at ${i_host}."
                fi
            fi
        fi

        # Determine databases/buckets to back up
        if [ "$IF_ALL" = "true" ]; then
            if [ "$IF_DRY_RUN" = "true" ]; then
                if_process_database "$i_container" "$i_host" "$i_version" "_all" "$i_token" "$i_org" "$i_user" "$i_pass"
            elif [ "$i_version" = "2" ]; then
                # InfluxDB 2.x: --all means full backup (no --bucket flag)
                if [ -z "$i_token" ]; then
                    if_error "InfluxDB 2.x full backup requires --token."
                    if_add_result "$i_container" "$i_version" "_all" "FAIL" 0 0 "" "no token"
                    continue
                fi
                [ -z "$i_org" ] && { if_error "InfluxDB 2.x full backup requires --org."; if_add_result "$i_container" "$i_version" "_all" "FAIL" 0 0 "" "no org"; continue; }
                local start_ts end_ts elapsed rc=0
                start_ts=$(date +%s)
                influx backup --host "$i_host" --token "$i_token" --org "$i_org" "$IF_OUTPUT_DIR/full-v2" 2>&1 >&2 || rc=$?
                end_ts=$(date +%s)
                elapsed=$((end_ts - start_ts))
                if [ "$rc" -eq 0 ]; then
                    local size
                    size="$(if_dir_size "${IF_OUTPUT_DIR}/full-v2")"
                    if_success "Full backup OK: ${i_container}/v2 ($(if_human_size "$size"), ${elapsed}s)"
                    if_add_result "$i_container" "$i_version" "_all" "OK" "$size" "$elapsed" "${IF_OUTPUT_DIR}/full-v2" ""
                else
                    if_error "Full backup FAILED: ${i_container}/v2 (exit ${rc})"
                    if_add_result "$i_container" "$i_version" "_all" "FAIL" 0 "$elapsed" "" "influx backup exit ${rc}"
                fi
            else
                # InfluxDB 1.x: --all means full backup (no -database flag)
                local start_ts end_ts elapsed rc=0
                start_ts=$(date +%s)
                local backup_cmd=(influxd backup -host "$i_host" "${IF_OUTPUT_DIR}/full-v1")
                if if_check_command influx && ! if_check_command influxd; then
                    backup_cmd=(influx backup -host "$i_host" "${IF_OUTPUT_DIR}/full-v1")
                fi
                "${backup_cmd[@]}" 2>&1 >&2 || rc=$?
                end_ts=$(date +%s)
                elapsed=$((end_ts - start_ts))
                if [ "$rc" -eq 0 ]; then
                    local size
                    size="$(if_dir_size "${IF_OUTPUT_DIR}/full-v1")"
                    if_success "Full backup OK: ${i_container}/v1 ($(if_human_size "$size"), ${elapsed}s)"
                    if_add_result "$i_container" "$i_version" "_all" "OK" "$size" "$elapsed" "${IF_OUTPUT_DIR}/full-v1" ""
                else
                    if_error "Full backup FAILED: ${i_container}/v1 (exit ${rc})"
                    if_add_result "$i_container" "$i_version" "_all" "FAIL" 0 "$elapsed" "" "influx backup exit ${rc}"
                fi
            fi
        else
            if_process_database "$i_container" "$i_host" "$i_version" "$IF_DATABASE" "$i_token" "$i_org" "$i_user" "$i_pass"
        fi
    done <<< "$instances"

    overall_end_ts=$(date +%s)
    overall_elapsed=$((overall_end_ts - overall_start_ts))

    # ── 3. Generate report ───────────────────────────────────────────────────
    if_step "Step 3/3 — Generating report"

    if_generate_report_text > "$report"
    if_detail "Text report: ${report}"

    if_generate_report_json > "$json_report"
    if_detail "JSON report: ${json_report}"

    local fail_count
    fail_count="$(echo "$IF_RESULTS" | grep -c '|FAIL|' 2>/dev/null || true)"

    if [ "$fail_count" -eq 0 ]; then
        if_success "InfluxDB backup completed (all OK, ${overall_elapsed}s)."
        if_log_file "influxdb-dump: PASS (elapsed=${overall_elapsed}s)"
    else
        if_error "InfluxDB backup FAILED — ${fail_count} database(s) failed."
        if_log_file "influxdb-dump: FAIL (failed=${fail_count}, elapsed=${overall_elapsed}s)"
    fi

    if [ "$IF_DRY_RUN" = "false" ]; then
        if_info ""
        if_info "Backup files are in: ${IF_OUTPUT_DIR}"
        if_info "Include this directory in your Restic/Kopia backup paths."
    fi

    if [ "$fail_count" -gt 0 ]; then
        return 1
    fi
    return 0
}

# Run main only when executed directly (not sourced)
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    if_main
    exit $?
fi
