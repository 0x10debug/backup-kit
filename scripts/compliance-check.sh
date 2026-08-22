#!/usr/bin/env bash
# scripts/compliance-check.sh — 3-2-1 backup compliance checker
#
# backup-kit: encrypted, automated, tested recovery for VPS and Docker.
# Homepage: https://github.com/0x10debug/backup-kit
#
# The 3-2-1 rule of backup:
#   3 — Keep at least THREE copies of your data (1 working + 2 backup)
#   2 — Store copies on at least TWO different types of media
#   1 — Keep at least ONE copy off-site / off-line
#
# This script performs a read-only audit of your backup configuration and
# reports PASS / WARN / FAIL for each criterion, plus an overall verdict.
# It does NOT modify any files, run any backups, or access any repositories.
#
# Usage:
#   compliance-check.sh [OPTIONS]
#
# Options:
#   --config-dir PATH    Override the config directory (default: /etc/mb-backup)
#   --state-dir PATH     Override the state directory (default: /var/lib/mb-backup)
#   --report PATH        Write the report to this file (default: stdout)
#   --json               Output a machine-readable JSON report (stdout)
#   --quiet, -q          Suppress human-readable output (use with --report or --json)
#   --help, -h           Show this help
#
# Exit codes:
#   0  All checks PASS
#   1  One or more checks WARN or FAIL
#   2  Invalid arguments

set -euo pipefail

# ── Constants ────────────────────────────────────────────────────────────────

readonly CC_VERSION="1.0.0"
readonly CC_HOMEPAGE="https://github.com/0x10debug/backup-kit"

# ── Defaults ─────────────────────────────────────────────────────────────────

CC_CONFIG_DIR="${MB_CONFIG_DIR:-/etc/mb-backup}"
CC_STATE_DIR="${MB_STATE_DIR:-/var/lib/mb-backup}"
CC_REPORT_FILE=""
CC_JSON=false
CC_QUIET=false

# Also look at the repo-local strategies directory for strategy.conf files
CC_REPO_DIR=""
if [ -n "${MB_BACKUP_DIR:-}" ]; then
    CC_REPO_DIR="${MB_BACKUP_DIR}"
else
    # Resolve relative to this script (../strategies)
    CC_REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
CC_STRATEGIES_DIR="${CC_REPO_DIR}/strategies"

# Known strategies
CC_KNOWN_STRATEGIES=(restic-s3 restic-sftp kopia-s3 borgmatic)

# ── Logging helpers ──────────────────────────────────────────────────────────

cc_log() {
    local level="$1"; shift
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    printf '[%s] %s %s\n' "$ts" "$level" "$*"
}

cc_info()    { $CC_QUIET || cc_log "INFO" "$*" >&2; }
cc_success() { $CC_QUIET || cc_log "OK"   "$*" >&2; }
cc_warn()    { $CC_QUIET || cc_log "WARN" "$*" >&2; }
cc_error()   { $CC_QUIET || cc_log "ERROR" "$*" >&2; }
cc_step()    { $CC_QUIET || printf '\n==> %s\n' "$*" >&2; }
cc_detail()  { $CC_QUIET || printf '    %s\n' "$*" >&2; }

# ── Argument parsing ─────────────────────────────────────────────────────────

cc_show_help() {
    cat <<'HELP'
compliance-check.sh — 3-2-1 backup compliance checker

Performs a read-only audit of your backup configuration against the 3-2-1 rule:
  3 copies of data, 2 media types, 1 off-site/off-line copy.

Usage:
  compliance-check.sh [OPTIONS]

Options:
  --config-dir PATH    Override the config directory (default: /etc/mb-backup)
  --state-dir PATH     Override the state directory (default: /var/lib/mb-backup)
  --report PATH        Write the report to this file (default: stdout)
  --json               Output a machine-readable JSON report (stdout)
  --quiet, -q          Suppress human-readable output (use with --report or --json)
  --help, -h           Show this help

Homepage: https://github.com/0x10debug/backup-kit
HELP
}

while [ $# -gt 0 ]; do
    case "$1" in
        --config-dir) CC_CONFIG_DIR="$2"; shift 2 ;;
        --state-dir)  CC_STATE_DIR="$2"; shift 2 ;;
        --report)     CC_REPORT_FILE="$2"; shift 2 ;;
        --json)       CC_JSON=true; shift ;;
        --quiet|-q)   CC_QUIET=true; shift ;;
        --version)    echo "compliance-check.sh ${CC_VERSION} (${CC_HOMEPAGE})"; exit 0 ;;
        --help|-h)    cc_show_help; exit 0 ;;
        *) cc_error "Unknown option: $1"; cc_show_help; exit 2 ;;
    esac
done

# ── Data collection ──────────────────────────────────────────────────────────

# Collect all configured backup destinations (repository URLs) and their media types.
# Returns lines of "strategy|repository_url|media_type" on stdout.
cc_collect_destinations() {
    local strategy env_file repo_url media_type

    for strategy in "${CC_KNOWN_STRATEGIES[@]}"; do
        env_file=""
        # Check deployed config first, then repo-local .env.example
        if [ -f "${CC_CONFIG_DIR}/${strategy}/.env" ]; then
            env_file="${CC_CONFIG_DIR}/${strategy}/.env"
        elif [ -f "${CC_STRATEGIES_DIR}/${strategy}/.env.example" ]; then
            env_file="${CC_STRATEGIES_DIR}/${strategy}/.env.example"
        fi

        [ -z "$env_file" ] && continue

        # Only count deployed configs (.env) as active destinations.
        # .env.example files are templates, not active configs.
        if [ "$env_file" = "${CC_STRATEGIES_DIR}/${strategy}/.env.example" ]; then
            continue
        fi

        repo_url=""
        media_type=""

        case "$strategy" in
            restic-s3|restic-sftp)
                repo_url="$(grep -E '^RESTIC_REPOSITORY=' "$env_file" 2>/dev/null | head -1 | cut -d'=' -f2- | tr -d '"' || true)"
                ;;
            kopia-s3)
                repo_url="$(grep -E '^KOPIA_REPOSITORY=' "$env_file" 2>/dev/null | head -1 | cut -d'=' -f2- | tr -d '"' || true)"
                ;;
            borgmatic)
                repo_url="$(grep -E '^BORG_REPO=' "$env_file" 2>/dev/null | head -1 | cut -d'=' -f2- | tr -d '"' || true)"
                ;;
        esac

        [ -z "$repo_url" ] && continue

        media_type="$(cc_classify_media "$repo_url" "$strategy")"
        echo "${strategy}|${repo_url}|${media_type}"
    done
}

# Classify a repository URL into a media type.
# Echoes one of: cloud-object, network-disk, local-disk, rclone, unknown
# The strategy name helps disambiguate bare identifiers (e.g. Kopia bucket names).
cc_classify_media() {
    local url="$1" strategy="${2:-}"
    case "$strategy" in
        kopia-s3) echo "cloud-object"; return 0 ;;
    esac
    case "$url" in
        s3:*)               echo "cloud-object" ;;
        sftp:*)             echo "network-disk" ;;
        rclone:*)           echo "rclone" ;;
        /*|*/*)             echo "local-disk" ;;
        *)
            # Borgmatic repos: user@host:path → network-disk
            if echo "$url" | grep -qE '^[^/[:space:]]+@'; then
                echo "network-disk"
            else
                echo "unknown"
            fi
            ;;
    esac
}

# Check for an offline copy indicator.
# Looks for:
#   1. MB_OFFLINE_COPY env var (set to "yes" or a path)
#   2. State file: ${CC_STATE_DIR}/offline-copy
#   3. A configured offline backup path that exists on disk
# Echoes "yes" or "no".
cc_check_offline() {
    # 1. Environment variable
    if [ -n "${MB_OFFLINE_COPY:-}" ] && [ "${MB_OFFLINE_COPY}" != "no" ] && [ "${MB_OFFLINE_COPY}" != "" ]; then
        echo "yes"
        return 0
    fi

    # 2. State file marker
    if [ -f "${CC_STATE_DIR}/offline-copy" ]; then
        echo "yes"
        return 0
    fi

    # 3. Config file with offline path
    local offline_path
    offline_path="$(grep -E '^MB_OFFLINE_COPY_PATH=' "${CC_CONFIG_DIR}/env.sh" 2>/dev/null \
        | head -1 | cut -d'=' -f2- | tr -d '"' || true)"
    if [ -n "$offline_path" ] && [ -e "$offline_path" ]; then
        echo "yes"
        return 0
    fi

    echo "no"
}

# ── Compliance checks ────────────────────────────────────────────────────────

# Each check function sets a global variable: CC_CHECK_<NAME>_STATUS and _DETAIL

CC_COPIES_STATUS=""
CC_COPIES_DETAIL=""
CC_MEDIA_STATUS=""
CC_MEDIA_DETAIL=""
CC_OFFLINE_STATUS=""
CC_OFFLINE_DETAIL=""

# 3 copies: 1 working copy + at least 2 backup destinations
cc_check_copies() {
    local dest_count
    dest_count="$(echo "$CC_DESTINATIONS" | grep -c . 2>/dev/null || true)"

    if [ "$dest_count" -ge 2 ]; then
        CC_COPIES_STATUS="PASS"
        CC_COPIES_DETAIL="${dest_count} backup destination(s) configured → $((dest_count + 1)) total copies (1 working + ${dest_count} backup)"
    elif [ "$dest_count" -eq 1 ]; then
        CC_COPIES_STATUS="WARN"
        CC_COPIES_DETAIL="Only 1 backup destination → 2 total copies. 3-2-1 requires at least 2 backup destinations (3 total copies)."
    else
        CC_COPIES_STATUS="FAIL"
        CC_COPIES_DETAIL="No backup destinations configured. Run 'mb backup init' to set up a backup strategy."
    fi
}

# 2 media types: at least 2 distinct media types among backup destinations
cc_check_media() {
    local media_types media_count
    media_types="$(echo "$CC_DESTINATIONS" | cut -d'|' -f3 | sort -u)"
    media_count="$(echo "$media_types" | grep -c . 2>/dev/null || true)"

    if [ "$media_count" -ge 2 ]; then
        CC_MEDIA_STATUS="PASS"
        CC_MEDIA_DETAIL="${media_count} distinct media type(s): $(echo "$media_types" | tr '\n' ', ' | sed 's/,$//')"
    elif [ "$media_count" -eq 1 ]; then
        CC_MEDIA_STATUS="WARN"
        CC_MEDIA_DETAIL="Only 1 media type: $(echo "$media_types" | head -1). 3-2-1 requires at least 2 different media types."
    else
        CC_MEDIA_STATUS="FAIL"
        CC_MEDIA_DETAIL="No media types detected (no backup destinations configured)."
    fi
}

# 1 offline: at least 1 offline/off-site copy
cc_check_offline_copy() {
    local offline
    offline="$(cc_check_offline)"

    if [ "$offline" = "yes" ]; then
        CC_OFFLINE_STATUS="PASS"
        CC_OFFLINE_DETAIL="Offline/off-site copy indicator found."
    else
        CC_OFFLINE_STATUS="WARN"
        CC_OFFLINE_DETAIL="No offline copy detected. To mark an offline copy, set MB_OFFLINE_COPY=yes, create ${CC_STATE_DIR}/offline-copy, or set MB_OFFLINE_COPY_PATH in ${CC_CONFIG_DIR}/env.sh."
    fi
}

# ── Report generation ────────────────────────────────────────────────────────

cc_determine_overall() {
    local overall="PASS"
    for status in "$CC_COPIES_STATUS" "$CC_MEDIA_STATUS" "$CC_OFFLINE_STATUS"; do
        case "$status" in
            FAIL) overall="FAIL"; break ;;
            WARN) [ "$overall" != "FAIL" ] && overall="WARN" ;;
        esac
    done
    echo "$overall"
}

cc_generate_report_text() {
    local overall
    overall="$(cc_determine_overall)"

    local dest_count
    dest_count="$(echo "$CC_DESTINATIONS" | grep -c . 2>/dev/null || true)"

    cat <<EOF
==========================================
 backup-kit 3-2-1 Compliance Report
==========================================
Date       : $(date '+%Y-%m-%d %H:%M:%S')
Config dir : ${CC_CONFIG_DIR}
State dir  : ${CC_STATE_DIR}

---- Backup destinations (${dest_count}) ----
EOF

    if [ "$dest_count" -gt 0 ]; then
        echo "$CC_DESTINATIONS" | while IFS='|' read -r strat repo media; do
            printf "  %-16s %-40s [%s]\n" "$strat" "$repo" "$media"
        done
    else
        echo "  (none configured)"
    fi

    cat <<EOF

---- 3-2-1 Checks ----

[1] THREE copies (1 working + 2 backup)
    Status  : ${CC_COPIES_STATUS}
    Detail  : ${CC_COPIES_DETAIL}

[2] TWO different media types
    Status  : ${CC_MEDIA_STATUS}
    Detail  : ${CC_MEDIA_DETAIL}

[3] ONE off-site / off-line copy
    Status  : ${CC_OFFLINE_STATUS}
    Detail  : ${CC_OFFLINE_DETAIL}

---- Overall verdict ----
Result     : ${overall}

EOF

    case "$overall" in
        PASS) echo "Your backup strategy meets the 3-2-1 rule." ;;
        WARN) echo "Your backup strategy has gaps. Review the WARN items above." ;;
        FAIL) echo "Your backup strategy does NOT meet the 3-2-1 rule. Action required." ;;
    esac

    echo "=========================================="
}

cc_generate_report_json() {
    local overall
    overall="$(cc_determine_overall)"
    local dest_count
    dest_count="$(echo "$CC_DESTINATIONS" | grep -c . 2>/dev/null || true)"

    # Build destinations array (avoid subshell so variables persist)
    local dest_json="[]"
    if [ "$dest_count" -gt 0 ]; then
        dest_json=""
        local first=true
        while IFS='|' read -r strat repo media; do
            [ -z "$strat" ] && continue
            if [ "$first" = "true" ]; then
                first=false
            else
                dest_json="${dest_json},"
            fi
            dest_json="${dest_json}{\"strategy\":\"${strat}\",\"repository\":\"${repo}\",\"media_type\":\"${media}\"}"
        done <<< "$CC_DESTINATIONS"
        dest_json="[${dest_json}]"
    fi

    cat <<EOF
{
  "tool": "backup-kit compliance-check",
  "version": "${CC_VERSION}",
  "timestamp": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "config_dir": "${CC_CONFIG_DIR}",
  "state_dir": "${CC_STATE_DIR}",
  "destinations": ${dest_json},
  "checks": {
    "copies": {
      "status": "${CC_COPIES_STATUS}",
      "detail": "${CC_COPIES_DETAIL}"
    },
    "media_types": {
      "status": "${CC_MEDIA_STATUS}",
      "detail": "${CC_MEDIA_DETAIL}"
    },
    "offline": {
      "status": "${CC_OFFLINE_STATUS}",
      "detail": "${CC_OFFLINE_DETAIL}"
    }
  },
  "overall": "${overall}"
}
EOF
}

# ── Main ─────────────────────────────────────────────────────────────────────

cc_main() {
    cc_step "3-2-1 Backup Compliance Check"

    # Collect destinations
    CC_DESTINATIONS="$(cc_collect_destinations)"

    local dest_count
    dest_count="$(echo "$CC_DESTINATIONS" | grep -c . 2>/dev/null || true)"
    cc_info "Found ${dest_count} backup destination(s)."

    # Run checks
    cc_check_copies
    cc_check_media
    cc_check_offline_copy

    # Report results to stderr (human-readable)
    if [ "$CC_QUIET" = "false" ] && [ "$CC_JSON" = "false" ]; then
        cc_info ""
        cc_info "[1] THREE copies  →  ${CC_COPIES_STATUS}"
        cc_detail "${CC_COPIES_DETAIL}"
        cc_info "[2] TWO media     →  ${CC_MEDIA_STATUS}"
        cc_detail "${CC_MEDIA_DETAIL}"
        cc_info "[3] ONE offline   →  ${CC_OFFLINE_STATUS}"
        cc_detail "${CC_OFFLINE_DETAIL}"
    fi

    # Generate report
    local overall
    overall="$(cc_determine_overall)"

    if [ "$CC_JSON" = "true" ]; then
        cc_generate_report_json
    else
        cc_generate_report_text
    fi | {
        if [ -n "$CC_REPORT_FILE" ]; then
            mkdir -p "$(dirname "$CC_REPORT_FILE")" 2>/dev/null || true
            cat > "$CC_REPORT_FILE"
            cc_info "Report written to ${CC_REPORT_FILE}"
        else
            cat
        fi
    }

    # Exit code
    case "$overall" in
        PASS) cc_success "Compliance check: PASS"; exit 0 ;;
        WARN) cc_warn "Compliance check: WARN"; exit 1 ;;
        FAIL) cc_error "Compliance check: FAIL"; exit 1 ;;
    esac
}

cc_main
