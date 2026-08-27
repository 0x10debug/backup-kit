#!/usr/bin/env bash
# lib/es-dump.sh — Elasticsearch-aware backup for backup-kit
#
# backup-kit: encrypted, automated, tested recovery for VPS and Docker.
# Homepage: https://github.com/0x10debug/backup-kit
#
# This library provides Elasticsearch index backup capabilities. It can be
# sourced by volume-backup.sh or db-backup.sh, or run standalone.
#
# Two backup methods are supported:
#   elasticdump  — Export index data as JSON via the elasticdump CLI tool.
#                  Good for small to medium indices, portable, no ES config
#                  changes needed.
#   snapshot     — Use the Elasticsearch Snapshot/Restore API to create
#                  repository snapshots. Requires a registered snapshot
#                  repository. Best for large clusters and point-in-time
#                  consistency.
#
# Targets can be discovered automatically by scanning running Docker
# containers for the label `backup.es-cluster`, or specified manually.
#
# Usage (standalone):
#   es-dump.sh [OPTIONS]
#
# Options:
#   --auto                    Auto-discover ES clusters via Docker container labels
#   --host URL                Elasticsearch host URL (e.g., http://localhost:9200)
#   --index NAME              Index name to back up (repeatable; or --all-indices)
#   --all-indices             Back up all indices
#   --method METHOD           Backup method: elasticdump|snapshot (default: elasticdump)
#   --snapshot-repo NAME      Snapshot repository name (for --method snapshot)
#   --container NAME          Docker container running ES (exec into it)
#   --output-dir PATH         Output directory for dumps (default: /backup/es-dumps-<ts>)
#   --dry-run                 Preview without writing dumps
#   --help, -h                Show this help
#
# Exit codes:
#   0  All dumps succeeded (or dry-run completed)
#   1  One or more dumps failed
#   2  Invalid arguments / missing prerequisites

set -euo pipefail

# ── Constants ────────────────────────────────────────────────────────────────

readonly ES_VERSION="1.0.0"
readonly ES_HOMEPAGE="https://github.com/0x10debug/backup-kit"

readonly ES_SUPPORTED_METHODS=(elasticdump snapshot)

# Docker label used for auto-discovery
readonly ES_LABEL="backup.es-cluster"

# ── Color variables ──────────────────────────────────────────────────────────

if [ -t 1 ]; then
    readonly ES_C_FAIL='\033[0;31m'
    readonly ES_C_OK='\033[0;32m'
    readonly ES_C_WARN='\033[0;33m'
    readonly ES_C_INFO='\033[0;34m'
    readonly ES_C_RST='\033[0m'
else
    readonly ES_C_FAIL=''
    readonly ES_C_OK=''
    readonly ES_C_WARN=''
    readonly ES_C_INFO=''
    readonly ES_C_RST=''
fi

# ── Defaults ─────────────────────────────────────────────────────────────────

ES_MODE=""              # "auto" or "manual"
ES_HOST=""
ES_INDICES=()
ES_ALL_INDICES=false
ES_METHOD="elasticdump"
ES_SNAPSHOT_REPO=""
ES_CONTAINER=""
ES_OUTPUT_DIR=""
ES_DRY_RUN=false

# Resolved at runtime
ES_STATE_DIR="${MB_STATE_DIR:-/var/lib/mb-backup}"
ES_LOG_FILE="${MB_LOG_FILE:-/var/log/mb-backup.log}"
ES_BACKUP_TMP="${MB_BACKUP_TMP:-/backup}"

# Accumulated results
# Each entry: "cluster|index|method|status|size_bytes|duration_s|dump_file|error"
ES_RESULTS=""

# ── Logging helpers ──────────────────────────────────────────────────────────

es_log() {
    local level="$1"; shift
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    printf '[%s] %s %s\n' "$ts" "$level" "$*"
}

es_info()    { es_log "${ES_C_INFO}INFO${ES_C_RST}" "$*" >&2; }
es_success() { printf "${ES_C_OK}%s${ES_C_RST}\n" "$*" >&2; }
es_warn()    { printf "${ES_C_WARN}WARN: %s${ES_C_RST}\n" "$*" >&2; }
es_error()   { printf "${ES_C_FAIL}ERROR: %s${ES_C_RST}\n" "$*" >&2; }
es_step()    { printf '\n==> %s\n' "$*" >&2; }
es_detail()  { printf '    %s\n' "$*" >&2; }

es_log_file() {
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    ( mkdir -p "$(dirname "$ES_LOG_FILE")" 2>/dev/null
      echo "[${ts}] $*" >> "$ES_LOG_FILE" ) 2>/dev/null || true
}

es_die() {
    es_error "$*"
    es_log_file "es-dump: FATAL: $*"
    exit 2
}

# ── Argument parsing ─────────────────────────────────────────────────────────

es_show_help() {
    cat <<'HELP'
es-dump.sh — Elasticsearch-aware backup

Backs up Elasticsearch indices using elasticdump (JSON export) or the
Snapshot/Restore API. Supports Docker container auto-discovery and
manual mode.

Usage:
  es-dump.sh --auto [OPTIONS]
  es-dump.sh --host URL --index NAME [OPTIONS]
  es-dump.sh --host URL --all-indices [OPTIONS]

Options:
  --auto                    Auto-discover ES clusters via Docker container labels
  --host URL                Elasticsearch host URL (e.g., http://localhost:9200)
  --index NAME              Index name to back up (repeatable; or --all-indices)
  --all-indices             Back up all indices
  --method METHOD           Backup method: elasticdump|snapshot (default: elasticdump)
  --snapshot-repo NAME      Snapshot repository name (for --method snapshot)
  --container NAME          Docker container running ES (exec into it)
  --output-dir PATH         Output directory for dumps (default: /backup/es-dumps-<ts>)
  --dry-run                 Preview without writing dumps
  --help, -h                Show this help

Docker auto-discovery:
  Containers with the label `backup.es-cluster` are automatically detected.
  The label value is used as the cluster name. Additional labels:
    backup.es-port=PORT       ES port (default: 9200)
    backup.es-method=METHOD   Backup method override

Methods:
  elasticdump  — Export each index as JSON (mapping + data) via elasticdump.
                 Requires elasticdump installed (npm install -g elasticdump).
  snapshot     — Create a snapshot via the ES Snapshot/Restore API.
                 Requires a registered snapshot repository (--snapshot-repo).

Homepage: https://github.com/0x10debug/backup-kit
HELP
}

# Parse arguments only when run standalone (not sourced)
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    while [ $# -gt 0 ]; do
        case "$1" in
            --auto)           ES_MODE="auto"; shift ;;
            --host)           ES_HOST="$2"; shift 2 ;;
            --index)          ES_INDICES+=("$2"); shift 2 ;;
            --all-indices)    ES_ALL_INDICES=true; shift ;;
            --method)         ES_METHOD="$2"; shift 2 ;;
            --snapshot-repo)  ES_SNAPSHOT_REPO="$2"; shift 2 ;;
            --container)      ES_CONTAINER="$2"; shift 2 ;;
            --output-dir)     ES_OUTPUT_DIR="$2"; shift 2 ;;
            --dry-run)        ES_DRY_RUN=true; shift ;;
            --version)        echo "es-dump.sh ${ES_VERSION} (${ES_HOMEPAGE})"; exit 0 ;;
            --help|-h)        es_show_help; exit 0 ;;
            *) es_error "Unknown option: $1"; es_show_help; exit 2 ;;
        esac
    done
fi

# ── Prerequisite checks ──────────────────────────────────────────────────────

es_check_command() {
    command -v "$1" >/dev/null 2>&1
}

es_validate_method() {
    local m="$1"
    for valid in "${ES_SUPPORTED_METHODS[@]}"; do
        [ "$m" = "$valid" ] && return 0
    done
    return 1
}

# ── Utility functions ────────────────────────────────────────────────────────

es_safe_name() {
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

es_file_size() {
    local file="$1"
    if [ -f "$file" ]; then
        wc -c < "$file" 2>/dev/null | tr -d '[:space:]' || echo 0
    else
        echo 0
    fi
}

es_human_size() {
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

es_json_escape() {
    local s="${1:-}"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    printf '%s' "$s"
}

# ── Docker auto-discovery ────────────────────────────────────────────────────

# Scan running Docker containers for the backup.es-cluster label.
# Echoes one line per discovered cluster:
#   "container|host|port|method|cluster_name"
es_discover_clusters() {
    if ! es_check_command docker; then
        es_warn "docker is not installed — auto-discovery unavailable."
        return 0
    fi

    local container_ids
    container_ids="$(docker ps --filter "label=${ES_LABEL}" --format '{{.ID}}' 2>/dev/null || true)"

    if [ -z "$container_ids" ]; then
        es_info "No Docker containers with label '${ES_LABEL}' found."
        return 0
    fi

    local cid
    while IFS= read -r cid; do
        [ -z "$cid" ] && continue
        local ccluster cport cmethod ccontainer_name chost

        ccluster="$(docker inspect --format "{{ index .Config.Labels \"${ES_LABEL}\" }}" "$cid" 2>/dev/null || true)"
        cport="$(docker inspect --format "{{ index .Config.Labels \"backup.es-port\" }}" "$cid" 2>/dev/null || true)"
        cmethod="$(docker inspect --format "{{ index .Config.Labels \"backup.es-method\" }}" "$cid" 2>/dev/null || true)"
        ccontainer_name="$(docker inspect --format '{{.Name}}' "$cid" 2>/dev/null | sed 's|^/||' || true)"

        [ -z "$cport" ] && cport="9200"
        [ -z "$cmethod" ] && cmethod="$ES_METHOD"
        [ -z "$ccluster" ] && ccluster="$ccontainer_name"

        # For Docker-based ES, we connect to the container's published port on localhost
        chost="http://localhost:${cport}"

        echo "${ccontainer_name}|${chost}|${cport}|${cmethod}|${ccluster}"
    done <<< "$container_ids"
}

# ── Index listing ────────────────────────────────────────────────────────────

# List all indices for an ES host (excluding system indices).
# Args: host_url
es_list_indices() {
    local host="$1"
    if es_check_command curl; then
        curl -s "${host}/_cat/indices?h=index" 2>/dev/null \
            | grep -v '^\.' || true
    fi
}

# ── Backup methods ───────────────────────────────────────────────────────────

# Dump a single index using elasticdump (mapping + data).
# Args: host index output_dir
es_dump_index_elasticdump() {
    local host="$1" index="$2" out_dir="$3"
    local safe_name mapping_file data_file

    safe_name="$(es_safe_name "$index")"
    mapping_file="${out_dir}/${safe_name}.mapping.json"
    data_file="${out_dir}/${safe_name}.data.json"

    # Export mapping (analyzer, settings)
    elasticdump \
        --input="${host}/${index}" \
        --output="$mapping_file" \
        --type=mapping 2>&1 >&2

    # Export data (documents)
    elasticdump \
        --input="${host}/${index}" \
        --output="$data_file" \
        --type=data 2>&1 >&2

    # Return the combined size
    local mapping_size data_size
    mapping_size="$(es_file_size "$mapping_file")"
    data_size="$(es_file_size "$data_file")"
    echo "$((mapping_size + data_size))"
}

# Create a snapshot of an index (or all indices) via the Snapshot API.
# Args: host index_or_all snapshot_repo
es_dump_index_snapshot() {
    local host="$1" index="$2" repo="$3"
    local snapshot_name
    snapshot_name="es-snap-$(date '+%Y%m%d-%H%M%S')-$(es_safe_name "$index")"

    if es_check_command curl; then
        local snap_path
        if [ "$index" = "_all" ]; then
            snap_path="${host}/_snapshot/${repo}/${snapshot_name}?wait_for_completion=true"
        else
            snap_path="${host}/_snapshot/${repo}/${snapshot_name}?wait_for_completion=true&indices=${index}"
        fi
        curl -s -X PUT "$snap_path" >/dev/null 2>&1
    else
        es_error "curl is required for snapshot method."
        return 1
    fi
}

# ── Report helpers ───────────────────────────────────────────────────────────

es_add_result() {
    local entry
    entry="$(printf '%s|' "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8")"
    entry="${entry%|}"
    if [ -z "$ES_RESULTS" ]; then
        ES_RESULTS="$entry"
    else
        ES_RESULTS="${ES_RESULTS}
${entry}"
    fi
}

es_generate_report_text() {
    local total success_count fail_count
    total="$(echo "$ES_RESULTS" | grep -c . 2>/dev/null || true)"
    success_count="$(echo "$ES_RESULTS" | grep -c '|OK|' 2>/dev/null || true)"
    fail_count="$(echo "$ES_RESULTS" | grep -c '|FAIL|' 2>/dev/null || true)"

    {
        echo "=========================================="
        echo " backup-kit Elasticsearch Backup Report"
        echo "=========================================="
        echo "Date       : $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Mode       : ${ES_MODE}"
        echo "Method     : ${ES_METHOD}"
        echo "Dry-run    : ${ES_DRY_RUN}"
        echo "Output dir : ${ES_OUTPUT_DIR}"
        echo ""
        echo "---- Summary ----"
        echo "Total indices  : ${total}"
        echo "Succeeded      : ${success_count}"
        echo "Failed         : ${fail_count}"
        echo ""
        echo "---- Details ----"

        if [ "$total" -gt 0 ]; then
            printf "%-20s %-25s %-12s %-8s %-12s %-10s %s\n" \
                "Cluster" "Index" "Method" "Status" "Size" "Duration" "File"
            printf '%.0s-' {1..110}
            echo ""

            while IFS='|' read -r rcluster rindex rmethod rstatus rsize rduration rdumpfile rerror; do
                local size_human
                size_human="$(es_human_size "$rsize")"
                printf "%-20s %-25s %-12s %-8s %-12s %-10s %s\n" \
                    "$rcluster" "$rindex" "$rmethod" "$rstatus" "$size_human" "${rduration}s" "$(basename "$rdumpfile")"
                if [ "$rstatus" = "FAIL" ] && [ -n "$rerror" ]; then
                    printf "                    Error: %s\n" "$rerror"
                fi
            done <<< "$ES_RESULTS"
        else
            echo "  (no indices processed)"
        fi

        echo ""
        echo "---- Verdict ----"
        if [ "$fail_count" -eq 0 ]; then
            echo "Result           : PASS"
        else
            echo "Result           : FAIL (${fail_count} index(es) failed)"
        fi
        echo "=========================================="
    }
}

es_generate_report_json() {
    local total success_count fail_count
    total="$(echo "$ES_RESULTS" | grep -c . 2>/dev/null || true)"
    success_count="$(echo "$ES_RESULTS" | grep -c '|OK|' 2>/dev/null || true)"
    fail_count="$(echo "$ES_RESULTS" | grep -c '|FAIL|' 2>/dev/null || true)"

    local overall="PASS"
    [ "$fail_count" -gt 0 ] && overall="FAIL"

    local idx_json=""
    local first=true
    if [ "$total" -gt 0 ]; then
        while IFS='|' read -r rcluster rindex rmethod rstatus rsize rduration rdumpfile rerror; do
            [ -z "$rcluster" ] && continue
            if [ "$first" = "true" ]; then
                first=false
            else
                idx_json="${idx_json},"
            fi
            local esc_file esc_error
            esc_file="$(es_json_escape "$rdumpfile")"
            esc_error="$(es_json_escape "$rerror")"
            idx_json="${idx_json}{\"cluster\":\"${rcluster}\",\"index\":\"${rindex}\",\"method\":\"${rmethod}\",\"status\":\"${rstatus}\",\"size_bytes\":${rsize:-0},\"duration_s\":${rduration:-0},\"dump_file\":\"${esc_file}\",\"error\":\"${esc_error}\"}"
        done <<< "$ES_RESULTS"
    fi

    cat <<EOF
{
  "tool": "backup-kit es-dump",
  "version": "${ES_VERSION}",
  "timestamp": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "mode": "${ES_MODE}",
  "method": "${ES_METHOD}",
  "dry_run": ${ES_DRY_RUN},
  "output_dir": "${ES_OUTPUT_DIR}",
  "summary": {
    "total": ${total:-0},
    "succeeded": ${success_count:-0},
    "failed": ${fail_count:-0}
  },
  "indices": [${idx_json}],
  "overall": "${overall}"
}
EOF
}

# ── Core logic ───────────────────────────────────────────────────────────────

# Process a single index: run the dump, record the result.
# Args: cluster host index
es_process_index() {
    local cluster="$1" host="$2" index="$3"
    local label="${cluster}/${index}"

    if [ "$ES_DRY_RUN" = "true" ]; then
        es_info "[dry-run] Would dump: ${label} via ${ES_METHOD}"
        es_add_result "$cluster" "$index" "$ES_METHOD" "DRY-RUN" 0 0 "" ""
        return 0
    fi

    es_info "Dumping: ${label} via ${ES_METHOD}"
    local start_ts end_ts elapsed
    start_ts=$(date +%s)

    if [ "$ES_METHOD" = "elasticdump" ]; then
        if ! es_check_command elasticdump; then
            es_error "elasticdump is not installed. Install: npm install -g elasticdump"
            es_add_result "$cluster" "$index" "$ES_METHOD" "FAIL" 0 0 "" "elasticdump not found"
            return 1
        fi

        local size
        if size="$(es_dump_index_elasticdump "$host" "$index" "$ES_OUTPUT_DIR" 2>/dev/null)"; then
            end_ts=$(date +%s)
            elapsed=$((end_ts - start_ts))
            local safe_name
            safe_name="$(es_safe_name "$index")"
            es_success "Dump OK: ${label} ($(es_human_size "$size"), ${elapsed}s)"
            es_add_result "$cluster" "$index" "$ES_METHOD" "OK" "$size" "$elapsed" "${ES_OUTPUT_DIR}/${safe_name}.data.json" ""
        else
            local rc=$?
            end_ts=$(date +%s)
            elapsed=$((end_ts - start_ts))
            local err_msg="elasticdump exited with code ${rc}"
            es_error "Dump FAILED: ${label} — ${err_msg}"
            es_log_file "es-dump: FAIL — ${label}: ${err_msg}"
            es_add_result "$cluster" "$index" "$ES_METHOD" "FAIL" 0 "$elapsed" "" "$err_msg"
        fi
    elif [ "$ES_METHOD" = "snapshot" ]; then
        if [ -z "$ES_SNAPSHOT_REPO" ]; then
            es_error "Snapshot method requires --snapshot-repo NAME."
            es_add_result "$cluster" "$index" "$ES_METHOD" "FAIL" 0 0 "" "no snapshot repository specified"
            return 1
        fi

        if es_dump_index_snapshot "$host" "$index" "$ES_SNAPSHOT_REPO"; then
            end_ts=$(date +%s)
            elapsed=$((end_ts - start_ts))
            es_success "Snapshot OK: ${label} → ${ES_SNAPSHOT_REPO}"
            es_add_result "$cluster" "$index" "$ES_METHOD" "OK" 0 "$elapsed" "snapshot:${ES_SNAPSHOT_REPO}" ""
        else
            local rc=$?
            end_ts=$(date +%s)
            elapsed=$((end_ts - start_ts))
            local err_msg="snapshot API exited with code ${rc}"
            es_error "Snapshot FAILED: ${label} — ${err_msg}"
            es_log_file "es-dump: FAIL — ${label}: ${err_msg}"
            es_add_result "$cluster" "$index" "$ES_METHOD" "FAIL" 0 "$elapsed" "" "$err_msg"
        fi
    fi
}

# ── Main (standalone mode) ───────────────────────────────────────────────────

es_main() {
    # Validation
    if [ "$ES_MODE" != "auto" ] && [ -z "$ES_HOST" ]; then
        es_error "Either --auto or --host URL must be specified."
        es_show_help
        exit 2
    fi

    if [ -n "$ES_HOST" ] && [ "$ES_MODE" != "auto" ]; then
        ES_MODE="manual"
    fi

    es_validate_method "$ES_METHOD" || es_die "Unsupported method: $ES_METHOD (use: ${ES_SUPPORTED_METHODS[*]})"

    if [ "$ES_METHOD" = "snapshot" ] && [ -z "$ES_SNAPSHOT_REPO" ]; then
        es_die "--method snapshot requires --snapshot-repo NAME."
    fi

    if [ "${#ES_INDICES[@]}" -gt 0 ] && [ "$ES_ALL_INDICES" = "true" ]; then
        es_die "--index and --all-indices are mutually exclusive."
    fi

    if [ "${#ES_INDICES[@]}" -eq 0 ] && [ "$ES_ALL_INDICES" = "false" ]; then
        ES_ALL_INDICES=true
        es_info "No --index specified, defaulting to --all-indices."
    fi

    # Timestamp for default paths
    local ts
    ts="$(date '+%Y%m%d-%H%M%S')"
    if [ -z "$ES_OUTPUT_DIR" ]; then
        ES_OUTPUT_DIR="${ES_BACKUP_TMP}/es-dumps-${ts}"
    fi

    local report="${ES_STATE_DIR}/es-dump-${ts}.txt"
    local json_report="${report%.txt}.json"
    mkdir -p "$(dirname "$report")" 2>/dev/null || true

    es_step "Elasticsearch-aware backup"
    es_info "Mode     : $ES_MODE"
    es_info "Method   : $ES_METHOD"
    es_info "Dry-run  : $ES_DRY_RUN"
    es_info "Output   : $ES_OUTPUT_DIR"
    es_log_file "es-dump: started (mode=${ES_MODE}, method=${ES_METHOD}, dry-run=${ES_DRY_RUN})"

    local overall_start_ts overall_end_ts overall_elapsed
    overall_start_ts=$(date +%s)

    # ── 1. Collect targets ──────────────────────────────────────────────────
    es_step "Step 1/3 — Discovering Elasticsearch targets"

    local clusters=""
    if [ "$ES_MODE" = "auto" ]; then
        es_info "Auto-discovering ES clusters via Docker labels..."
        clusters="$(es_discover_clusters)"
        local auto_count
        auto_count="$(echo "$clusters" | grep -c . 2>/dev/null || true)"
        es_info "Discovered ${auto_count} ES cluster(s) via Docker labels."
    else
        clusters="${ES_CONTAINER:-manual}|${ES_HOST}|9200|${ES_METHOD}|manual"
    fi

    # ── 2. Run dumps ─────────────────────────────────────────────────────────
    es_step "Step 2/3 — Running Elasticsearch dumps"

    if [ "$ES_DRY_RUN" = "false" ]; then
        mkdir -p "$ES_OUTPUT_DIR"
        es_info "Output directory: ${ES_OUTPUT_DIR}"
    else
        es_info "DRY-RUN mode — no dumps will be written."
    fi

    local cluster_line
    while IFS= read -r cluster_line; do
        [ -z "$cluster_line" ] && continue
        local c_container c_host c_port c_method c_cluster
        IFS='|' read -r c_container c_host c_port c_method c_cluster <<< "$cluster_line"

        # Use the per-cluster method if it differs from the global default
        if [ -n "$c_method" ] && [ "$c_method" != "$ES_METHOD" ]; then
            es_info "Cluster '${c_cluster}' uses method: ${c_method}"
        fi
        # c_container and c_port are available for Docker exec mode
        es_detail "Cluster: ${c_cluster} (container: ${c_container:-none}, port: ${c_port})"

        # Determine indices to back up
        local indices_to_backup=""
        if [ "$ES_ALL_INDICES" = "true" ]; then
            if [ "$ES_DRY_RUN" = "true" ]; then
                indices_to_backup="_all"
            else
                indices_to_backup="$(es_list_indices "$c_host")"
                if [ -z "$indices_to_backup" ]; then
                    es_warn "No indices found at ${c_host}, or curl unavailable."
                    indices_to_backup="_all"
                fi
            fi
        else
            local idx
            for idx in "${ES_INDICES[@]}"; do
                if [ -z "$indices_to_backup" ]; then
                    indices_to_backup="$idx"
                else
                    indices_to_backup="${indices_to_backup}
${idx}"
                fi
            done
        fi

        while IFS= read -r index; do
            [ -z "$index" ] && continue
            es_process_index "$c_cluster" "$c_host" "$index"
        done <<< "$indices_to_backup"
    done <<< "$clusters"

    overall_end_ts=$(date +%s)
    overall_elapsed=$((overall_end_ts - overall_start_ts))

    # ── 3. Generate report ───────────────────────────────────────────────────
    es_step "Step 3/3 — Generating report"

    es_generate_report_text > "$report"
    es_detail "Text report: ${report}"

    es_generate_report_json > "$json_report"
    es_detail "JSON report: ${json_report}"

    local fail_count
    fail_count="$(echo "$ES_RESULTS" | grep -c '|FAIL|' 2>/dev/null || true)"

    if [ "$fail_count" -eq 0 ]; then
        es_success "Elasticsearch backup completed (all OK, ${overall_elapsed}s)."
        es_log_file "es-dump: PASS (elapsed=${overall_elapsed}s)"
    else
        es_error "Elasticsearch backup FAILED — ${fail_count} index(es) failed."
        es_log_file "es-dump: FAIL (failed=${fail_count}, elapsed=${overall_elapsed}s)"
    fi

    if [ "$ES_DRY_RUN" = "false" ]; then
        es_info ""
        es_info "Dump files are in: ${ES_OUTPUT_DIR}"
        es_info "Include this directory in your Restic/Kopia backup paths."
    fi

    if [ "$fail_count" -gt 0 ]; then
        return 1
    fi
    return 0
}

# Run main only when executed directly (not sourced)
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    es_main
    exit $?
fi
