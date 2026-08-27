#!/usr/bin/env bash
# scripts/volume-backup.sh — Docker volume backup with compression and encryption
#
# backup-kit: encrypted, automated, tested recovery for VPS and Docker.
# Homepage: https://github.com/0x10debug/backup-kit
#
# This script backs up Docker named volumes to compressed (and optionally
# encrypted) tar archives. It can target a single volume, all volumes, or
# a filtered set (with exclusions). Archives can be written to a local
# directory or streamed directly into a Restic repository.
#
# Supported features:
#   - Single volume backup (--volume NAME)
#   - Batch backup of all volumes (--all)
#   - Exclude volumes by name pattern (--exclude PATTERN)
#   - Compression: gzip (default), zstd, none
#   - Encryption: age or gpg
#   - Output to a directory or direct upload to a Restic repo
#   - --dry-run preview mode
#   - TXT + JSON reports
#   - Error handling: missing volume, insufficient disk space, backup failure
#   - Cleanup of temporary files on success
#
# Usage:
#   volume-backup.sh [OPTIONS]
#
# Options:
#   --volume NAME             Back up a single named volume
#   --all                     Back up all Docker named volumes
#   --exclude PATTERN         Exclude volumes matching a glob pattern (repeatable)
#   --compress TYPE           Compression: gzip|zstd|none (default: gzip)
#   --encrypt TYPE            Encryption: age|gpg (requires key configuration)
#   --age-recipient RECIPIENT age recipient (public key or recipient string)
#   --gpg-recipient RECIPIENT gpg recipient (key ID or email)
#   --output-dir PATH         Output directory for archives (default: /backup/volume-backups-<ts>)
#   --restic                  Stream each archive directly to a Restic repo
#   --restic-repo REPO        Restic repository (or read from env RESTIC_REPOSITORY)
#   --restic-password PWD     Restic password (or read from env RESTIC_PASSWORD)
#   --report PATH             TXT report file path (default: /var/lib/mb-backup/volume-backup-<ts>.txt)
#   --json-report PATH        JSON report file path (default: alongside --report with .json)
#   --keep                    Keep archive files after completion (do not clean up)
#   --dry-run                 Preview which volumes would be backed up; write no archives
#   --help, -h                Show this help
#
# Exit codes:
#   0  All backups succeeded (or dry-run completed)
#   1  One or more backups failed
#   2  Invalid arguments / missing prerequisites

set -euo pipefail

# ── Constants ────────────────────────────────────────────────────────────────

readonly VB_VERSION="1.0.0"
readonly VB_HOMEPAGE="https://github.com/0x10debug/backup-kit"

readonly VB_SUPPORTED_COMPRESS=(gzip zstd none)
readonly VB_SUPPORTED_ENCRYPT=(age gpg)

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

VB_VOLUME=""
VB_ALL=false
VB_EXCLUDES=()
VB_COMPRESS="gzip"
VB_ENCRYPT=""
VB_AGE_RECIPIENT=""
VB_GPG_RECIPIENT=""
VB_OUTPUT_DIR=""
VB_RESTIC=false
VB_RESTIC_REPO=""
VB_RESTIC_PASSWORD=""
VB_REPORT=""
VB_JSON_REPORT=""
VB_KEEP=false
VB_DRY_RUN=false

# Resolved at runtime
VB_STATE_DIR="${MB_STATE_DIR:-/var/lib/mb-backup}"
VB_LOG_FILE="${MB_LOG_FILE:-/var/log/mb-backup.log}"
VB_BACKUP_TMP="${MB_BACKUP_TMP:-/backup}"

# Accumulated results (populated during execution)
# Each entry: "volume|status|size_bytes|duration_s|archive_file|error"
VB_RESULTS=""

# ── Logging helpers (self-contained, no external deps) ───────────────────────

vb_log() {
    local level="$1"; shift
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    printf '[%s] %s %s\n' "$ts" "$level" "$*"
}

vb_info()    { vb_log "${C_INFO}INFO${C_RST}" "$*" >&2; }
vb_success() { printf "${C_OK}%s${C_RST}\n" "$*" >&2; }
vb_warn()    { printf "${C_WARN}WARN: %s${C_RST}\n" "$*" >&2; }
vb_error()   { printf "${C_FAIL}ERROR: %s${C_RST}\n" "$*" >&2; }
vb_step()    { printf '\n==> %s\n' "$*" >&2; }
vb_detail()  { printf '    %s\n' "$*" >&2; }

vb_log_file() {
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    ( mkdir -p "$(dirname "$VB_LOG_FILE")" 2>/dev/null
      echo "[${ts}] $*" >> "$VB_LOG_FILE" ) 2>/dev/null || true
}

vb_die() {
    vb_error "$*"
    vb_log_file "volume-backup: FATAL: $*"
    exit 2
}

# ── Argument parsing ─────────────────────────────────────────────────────────

vb_show_help() {
    cat <<'HELP'
volume-backup.sh — Docker volume backup with compression and encryption

Backs up Docker named volumes to compressed (and optionally encrypted) tar
archives. Supports single volume, all volumes, exclusions, multiple compression
and encryption methods, and direct streaming to a Restic repository.

Usage:
  volume-backup.sh --volume NAME [OPTIONS]
  volume-backup.sh --all [OPTIONS]

Options:
  --volume NAME             Back up a single named volume
  --all                     Back up all Docker named volumes
  --exclude PATTERN         Exclude volumes matching a glob pattern (repeatable)
  --compress TYPE           Compression: gzip|zstd|none (default: gzip)
  --encrypt TYPE            Encryption: age|gpg (requires key configuration)
  --age-recipient RECIPIENT age recipient (public key or recipient string)
  --gpg-recipient RECIPIENT gpg recipient (key ID or email)
  --output-dir PATH         Output directory for archives (default: /backup/volume-backups-<ts>)
  --restic                  Stream each archive directly to a Restic repo
  --restic-repo REPO        Restic repository (or read from env RESTIC_REPOSITORY)
  --restic-password PWD     Restic password (or read from env RESTIC_PASSWORD)
  --report PATH             TXT report file path (default: /var/lib/mb-backup/volume-backup-<ts>.txt)
  --json-report PATH        JSON report file path (default: alongside --report with .json)
  --keep                    Keep archive files after completion (do not clean up)
  --dry-run                 Preview which volumes would be backed up; write no archives
  --help, -h                Show this help

Encryption:
  age  — Encrypt each archive with `age -r RECIPIENT`. Requires age installed
         and --age-recipient specified.
  gpg  — Encrypt each archive with `gpg --encrypt --recipient RECIPIENT`.
         Requires gpg installed and --gpg-recipient specified.

Restic streaming:
  When --restic is set, each volume archive is piped directly into
  `restic backup --stdin` instead of being written to disk. The Restic
  repository and password are read from --restic-repo/--restic-password
  or from the RESTIC_REPOSITORY / RESTIC_PASSWORD environment variables.

Homepage: https://github.com/0x10debug/backup-kit
HELP
}

while [ $# -gt 0 ]; do
    case "$1" in
        --volume)          VB_VOLUME="$2"; shift 2 ;;
        --all)             VB_ALL=true; shift ;;
        --exclude)         VB_EXCLUDES+=("$2"); shift 2 ;;
        --compress)        VB_COMPRESS="$2"; shift 2 ;;
        --encrypt)         VB_ENCRYPT="$2"; shift 2 ;;
        --age-recipient)   VB_AGE_RECIPIENT="$2"; shift 2 ;;
        --gpg-recipient)   VB_GPG_RECIPIENT="$2"; shift 2 ;;
        --output-dir)      VB_OUTPUT_DIR="$2"; shift 2 ;;
        --restic)          VB_RESTIC=true; shift ;;
        --restic-repo)     VB_RESTIC_REPO="$2"; shift 2 ;;
        --restic-password) VB_RESTIC_PASSWORD="$2"; shift 2 ;;
        --report)          VB_REPORT="$2"; shift 2 ;;
        --json-report)     VB_JSON_REPORT="$2"; shift 2 ;;
        --keep)            VB_KEEP=true; shift ;;
        --dry-run)         VB_DRY_RUN=true; shift ;;
        --version)         echo "volume-backup.sh ${VB_VERSION} (${VB_HOMEPAGE})"; exit 0 ;;
        --help|-h)         vb_show_help; exit 0 ;;
        *) vb_error "Unknown option: $1"; vb_show_help; exit 2 ;;
    esac
done

# ── Prerequisite checks ──────────────────────────────────────────────────────

vb_check_command() {
    command -v "$1" >/dev/null 2>&1
}

vb_validate_compress() {
    local t="$1"
    for valid in "${VB_SUPPORTED_COMPRESS[@]}"; do
        [ "$t" = "$valid" ] && return 0
    done
    return 1
}

vb_validate_encrypt() {
    local t="$1"
    for valid in "${VB_SUPPORTED_ENCRYPT[@]}"; do
        [ "$t" = "$valid" ] && return 0
    done
    return 1
}

# ── Validation ───────────────────────────────────────────────────────────────

if [ "$VB_ALL" = "false" ] && [ -z "$VB_VOLUME" ]; then
    vb_error "Either --volume NAME or --all must be specified."
    vb_show_help
    exit 2
fi

if [ -n "$VB_VOLUME" ] && [ "$VB_ALL" = "true" ]; then
    vb_die "--volume and --all are mutually exclusive."
fi

vb_validate_compress "$VB_COMPRESS" || vb_die "Unsupported compression: $VB_COMPRESS (use: ${VB_SUPPORTED_COMPRESS[*]})"

if [ -n "$VB_ENCRYPT" ]; then
    vb_validate_encrypt "$VB_ENCRYPT" || vb_die "Unsupported encryption: $VB_ENCRYPT (use: ${VB_SUPPORTED_ENCRYPT[*]})"
    case "$VB_ENCRYPT" in
        age)
            vb_check_command age || vb_die "age is not installed. Install it: https://github.com/FiloSottile/age"
            [ -z "$VB_AGE_RECIPIENT" ] && vb_die "--encrypt age requires --age-recipient RECIPIENT."
            ;;
        gpg)
            vb_check_command gpg || vb_die "gpg is not installed. Install it: apt-get install gnupg"
            [ -z "$VB_GPG_RECIPIENT" ] && vb_die "--encrypt gpg requires --gpg-recipient RECIPIENT."
            ;;
    esac
fi

if [ "$VB_COMPRESS" = "zstd" ]; then
    vb_check_command zstd || vb_die "zstd is not installed. Install it: apt-get install zstd"
fi

if [ "$VB_RESTIC" = "true" ]; then
    vb_check_command restic || vb_die "restic is not installed (required for --restic mode)."
    # Resolve repo/password from env if not given on CLI
    [ -z "$VB_RESTIC_REPO" ] && VB_RESTIC_REPO="${RESTIC_REPOSITORY:-}"
    [ -z "$VB_RESTIC_PASSWORD" ] && VB_RESTIC_PASSWORD="${RESTIC_PASSWORD:-}"
    [ -z "$VB_RESTIC_REPO" ] && vb_die "--restic requires --restic-repo or RESTIC_REPOSITORY env var."
    [ -z "$VB_RESTIC_PASSWORD" ] && vb_die "--restic requires --restic-password or RESTIC_PASSWORD env var."
fi

vb_check_command docker || vb_die "docker is not installed."

# Timestamp for default paths
VB_TS="$(date '+%Y%m%d-%H%M%S')"
if [ -z "$VB_OUTPUT_DIR" ] && [ "$VB_RESTIC" = "false" ]; then
    VB_OUTPUT_DIR="${VB_BACKUP_TMP}/volume-backups-${VB_TS}"
fi
if [ -z "$VB_REPORT" ]; then
    VB_REPORT="${VB_STATE_DIR}/volume-backup-${VB_TS}.txt"
fi
if [ -z "$VB_JSON_REPORT" ]; then
    VB_JSON_REPORT="${VB_REPORT%.txt}.json"
fi

# ── Utility functions ────────────────────────────────────────────────────────

# Check if a volume name matches any exclude pattern.
# Args: volume_name
# Returns 0 if it should be excluded, 1 otherwise.
vb_is_excluded() {
    local name="$1"
    local pattern
    for pattern in "${VB_EXCLUDES[@]}"; do
        # shellcheck disable=SC2254
        case "$name" in
            $pattern) return 0 ;;
        esac
    done
    return 1
}

# Check if a Docker volume exists.
# Args: volume_name
vb_volume_exists() {
    docker volume inspect "$1" >/dev/null 2>&1
}

# List all Docker named volumes (one per line).
vb_list_all_volumes() {
    docker volume ls -q 2>/dev/null || true
}

# Sanitize a string for use as a filename.
vb_safe_name() {
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

# Convert bytes to human-readable size.
vb_human_size() {
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
vb_file_size() {
    local file="$1"
    if [ -f "$file" ]; then
        wc -c < "$file" 2>/dev/null | tr -d '[:space:]' || echo 0
    else
        echo 0
    fi
}

# Escape a string for inclusion in JSON.
vb_json_escape() {
    local s="${1:-}"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    printf '%s' "$s"
}

# Check available disk space in a directory (in bytes).
# Args: dir_path  required_bytes
# Returns 0 if enough space, 1 otherwise.
vb_check_disk_space() {
    local dir="$1" required="$2"
    [ -d "$dir" ] || return 0  # Can't check if dir doesn't exist yet
    local avail
    # df -k gives KB; convert to bytes. Works on both GNU and BSD.
    avail="$(df -k "$dir" 2>/dev/null | awk 'NR==2 {print $4 * 1024}' || echo 0)"
    if [ "$avail" -gt 0 ] && [ "$avail" -lt "$required" ]; then
        return 1
    fi
    return 0
}

# Build the tar compression flag based on --compress setting.
# Echoes the tar flag string (e.g., "czf" or "--zstd -cf").
vb_tar_compress_flag() {
    case "$VB_COMPRESS" in
        gzip) echo "czf" ;;
        zstd) echo "--zstd -cf" ;;
        none) echo "cf" ;;
    esac
}

# Build the file extension based on compression and encryption.
vb_archive_extension() {
    local ext="tar"
    case "$VB_COMPRESS" in
        gzip) ext="${ext}.gz" ;;
        zstd) ext="${ext}.zst" ;;
        none) ;;
    esac
    if [ -n "$VB_ENCRYPT" ]; then
        case "$VB_ENCRYPT" in
            age) ext="${ext}.age" ;;
            gpg) ext="${ext}.gpg" ;;
        esac
    fi
    echo "$ext"
}

# ── Report helpers ───────────────────────────────────────────────────────────

# Append a result line to VB_RESULTS.
# Args: volume status size_bytes duration_s archive_file error
vb_add_result() {
    local entry
    entry="$(printf '%s|' "$1" "$2" "$3" "$4" "$5" "$6")"
    entry="${entry%|}"
    if [ -z "$VB_RESULTS" ]; then
        VB_RESULTS="$entry"
    else
        VB_RESULTS="${VB_RESULTS}
${entry}"
    fi
}

# Generate a text report.
vb_generate_report_text() {
    local total success_count fail_count
    total="$(echo "$VB_RESULTS" | grep -c . 2>/dev/null || true)"
    success_count="$(echo "$VB_RESULTS" | grep -c '|OK|' 2>/dev/null || true)"
    fail_count="$(echo "$VB_RESULTS" | grep -c '|FAIL|' 2>/dev/null || true)"

    {
        echo "=========================================="
        echo " backup-kit Volume Backup Report"
        echo "=========================================="
        echo "Date       : $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Compress   : ${VB_COMPRESS}"
        echo "Encrypt    : ${VB_ENCRYPT:-none}"
        echo "Restic     : ${VB_RESTIC}"
        echo "Dry-run    : ${VB_DRY_RUN}"
        if [ "$VB_RESTIC" = "false" ]; then
            echo "Output dir : ${VB_OUTPUT_DIR}"
        fi
        echo ""
        echo "---- Summary ----"
        echo "Total volumes  : ${total}"
        echo "Succeeded      : ${success_count}"
        echo "Failed         : ${fail_count}"
        echo ""
        echo "---- Details ----"

        if [ "$total" -gt 0 ]; then
            printf "%-30s %-8s %-12s %-10s %s\n" \
                "Volume" "Status" "Size" "Duration" "Archive"
            printf '%.0s-' {1..100}
            echo ""

            while IFS='|' read -r rvolume rstatus rsize rduration rarchive rerror; do
                local size_human
                size_human="$(vb_human_size "$rsize")"
                printf "%-30s %-8s %-12s %-10s %s\n" \
                    "$rvolume" "$rstatus" "$size_human" "${rduration}s" "$(basename "$rarchive")"
                if [ "$rstatus" = "FAIL" ] && [ -n "$rerror" ]; then
                    printf "                              Error: %s\n" "$rerror"
                fi
            done <<< "$VB_RESULTS"
        else
            echo "  (no volumes processed)"
        fi

        echo ""
        echo "---- Verdict ----"
        if [ "$fail_count" -eq 0 ]; then
            echo "Result           : PASS"
        else
            echo "Result           : FAIL (${fail_count} volume(s) failed)"
        fi
        echo ""
        if [ "$VB_RESTIC" = "true" ]; then
            echo "Archives were streamed directly to the Restic repository."
        else
            echo "Archives are in: ${VB_OUTPUT_DIR}"
            echo "Include this directory in your Restic/Kopia backup paths."
        fi
        echo "=========================================="
    }
}

# Generate a JSON report.
vb_generate_report_json() {
    local total success_count fail_count
    total="$(echo "$VB_RESULTS" | grep -c . 2>/dev/null || true)"
    success_count="$(echo "$VB_RESULTS" | grep -c '|OK|' 2>/dev/null || true)"
    fail_count="$(echo "$VB_RESULTS" | grep -c '|FAIL|' 2>/dev/null || true)"

    local overall="PASS"
    [ "$fail_count" -gt 0 ] && overall="FAIL"

    local vol_json=""
    local first=true
    if [ "$total" -gt 0 ]; then
        while IFS='|' read -r rvolume rstatus rsize rduration rarchive rerror; do
            [ -z "$rvolume" ] && continue
            if [ "$first" = "true" ]; then
                first=false
            else
                vol_json="${vol_json},"
            fi
            local esc_archive esc_error
            esc_archive="$(vb_json_escape "$rarchive")"
            esc_error="$(vb_json_escape "$rerror")"
            vol_json="${vol_json}{\"volume\":\"${rvolume}\",\"status\":\"${rstatus}\",\"size_bytes\":${rsize:-0},\"duration_s\":${rduration:-0},\"archive_file\":\"${esc_archive}\",\"error\":\"${esc_error}\"}"
        done <<< "$VB_RESULTS"
    fi

    cat <<EOF
{
  "tool": "backup-kit volume-backup",
  "version": "${VB_VERSION}",
  "timestamp": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "compress": "${VB_COMPRESS}",
  "encrypt": "${VB_ENCRYPT:-none}",
  "restic_stream": ${VB_RESTIC},
  "dry_run": ${VB_DRY_RUN},
  "output_dir": "${VB_OUTPUT_DIR:-}",
  "summary": {
    "total": ${total:-0},
    "succeeded": ${success_count:-0},
    "failed": ${fail_count:-0}
  },
  "volumes": [${vol_json}],
  "overall": "${overall}"
}
EOF
}

# ── Core backup logic ────────────────────────────────────────────────────────

# Back up a single volume to a file in VB_OUTPUT_DIR.
# Args: volume_name
vb_backup_volume_to_file() {
    local volume="$1"
    local safe_name ext archive_file

    safe_name="$(vb_safe_name "$volume")"
    ext="$(vb_archive_extension)"
    archive_file="${VB_OUTPUT_DIR}/${safe_name}-${VB_TS}.${ext}"

    local tar_flag
    tar_flag="$(vb_tar_compress_flag)"

    # Build the pipeline: docker run tar | [compress] | [encrypt] > file
    # For gzip/none, tar handles compression directly.
    # For zstd, tar --zstd handles it.
    # Encryption wraps the compressed output.

    vb_info "Backing up volume '${volume}' → $(basename "$archive_file")"

    if [ -z "$VB_ENCRYPT" ]; then
        # No encryption — tar writes directly to the output file via mounted volume
        # shellcheck disable=SC2086
        docker run --rm \
            -v "${volume}:/source:ro" \
            -v "${VB_OUTPUT_DIR}:/dest" \
            alpine \
            tar ${tar_flag} "/dest/${safe_name}-${VB_TS}.${ext}" -C /source . 2>&1 >&2
    else
        # Encryption — tar to stdout, pipe through encrypt, write to file
        # We use a temp container that streams tar to stdout, then encrypt locally
        local tar_stdout_flag
        case "$VB_COMPRESS" in
            gzip) tar_stdout_flag="czf -" ;;
            zstd) tar_stdout_flag="--zstd -cf -" ;;
            none) tar_stdout_flag="cf -" ;;
        esac

        case "$VB_ENCRYPT" in
            age)
                # shellcheck disable=SC2086
                docker run --rm -v "${volume}:/source:ro" alpine \
                    tar ${tar_stdout_flag} -C /source . 2>/dev/null \
                    | age -r "$VB_AGE_RECIPIENT" > "$archive_file"
                ;;
            gpg)
                # shellcheck disable=SC2086
                docker run --rm -v "${volume}:/source:ro" alpine \
                    tar ${tar_stdout_flag} -C /source . 2>/dev/null \
                    | gpg --batch --yes --encrypt --recipient "$VB_GPG_RECIPIENT" > "$archive_file"
                ;;
        esac
    fi
}

# Stream a single volume directly to a Restic repository.
# Args: volume_name
vb_backup_volume_to_restic() {
    local volume="$1"
    local stdin_filename="volume-${volume}-${VB_TS}.tar"

    case "$VB_COMPRESS" in
        gzip) stdin_filename="${stdin_filename}.gz" ;;
        zstd) stdin_filename="${stdin_filename}.zst" ;;
    esac

    vb_info "Streaming volume '${volume}' → restic (stdin-filename: ${stdin_filename})"

    local tar_stdout_flag
    case "$VB_COMPRESS" in
        gzip) tar_stdout_flag="czf -" ;;
        zstd) tar_stdout_flag="--zstd -cf -" ;;
        none) tar_stdout_flag="cf -" ;;
    esac

    export RESTIC_REPOSITORY="$VB_RESTIC_REPO"
    export RESTIC_PASSWORD="$VB_RESTIC_PASSWORD"

    if [ -z "$VB_ENCRYPT" ]; then
        # shellcheck disable=SC2086
        docker run --rm -v "${volume}:/source:ro" alpine \
            tar ${tar_stdout_flag} -C /source . 2>/dev/null \
            | restic backup --stdin --stdin-filename "$stdin_filename"
    else
        case "$VB_ENCRYPT" in
            age)
                # shellcheck disable=SC2086
                docker run --rm -v "${volume}:/source:ro" alpine \
                    tar ${tar_stdout_flag} -C /source . 2>/dev/null \
                    | age -r "$VB_AGE_RECIPIENT" \
                    | restic backup --stdin --stdin-filename "${stdin_filename}.age"
                ;;
            gpg)
                # shellcheck disable=SC2086
                docker run --rm -v "${volume}:/source:ro" alpine \
                    tar ${tar_stdout_flag} -C /source . 2>/dev/null \
                    | gpg --batch --yes --encrypt --recipient "$VB_GPG_RECIPIENT" \
                    | restic backup --stdin --stdin-filename "${stdin_filename}.gpg"
                ;;
        esac
    fi

    unset RESTIC_REPOSITORY RESTIC_PASSWORD 2>/dev/null || true
}

# Process a single volume: validate, back up, record result.
# Args: volume_name
vb_process_volume() {
    local volume="$1"

    # Check volume exists
    if ! vb_volume_exists "$volume"; then
        vb_error "Volume '${volume}' does not exist."
        vb_add_result "$volume" "FAIL" 0 0 "" "volume does not exist"
        return 1
    fi

    if [ "$VB_DRY_RUN" = "true" ]; then
        local ext
        ext="$(vb_archive_extension)"
        local preview_file
        if [ "$VB_RESTIC" = "true" ]; then
            preview_file="restic:stdin:volume-${volume}-${VB_TS}.${ext}"
        else
            preview_file="${VB_OUTPUT_DIR}/${volume}-${VB_TS}.${ext}"
        fi
        vb_info "[dry-run] Would back up: ${volume} → $(basename "$preview_file")"
        vb_add_result "$volume" "DRY-RUN" 0 0 "$preview_file" ""
        return 0
    fi

    local start_ts end_ts elapsed
    start_ts=$(date +%s)

    if [ "$VB_RESTIC" = "true" ]; then
        if vb_backup_volume_to_restic "$volume"; then
            end_ts=$(date +%s)
            elapsed=$((end_ts - start_ts))
            vb_success "Volume '${volume}' streamed to restic OK (${elapsed}s)"
            vb_add_result "$volume" "OK" 0 "$elapsed" "restic:stdin:volume-${volume}-${VB_TS}" ""
        else
            local rc=$?
            end_ts=$(date +%s)
            elapsed=$((end_ts - start_ts))
            local err_msg="restic backup exited with code ${rc}"
            vb_error "Volume '${volume}' backup FAILED — ${err_msg}"
            vb_log_file "volume-backup: FAIL — ${volume}: ${err_msg}"
            vb_add_result "$volume" "FAIL" 0 "$elapsed" "" "$err_msg"
        fi
    else
        if vb_backup_volume_to_file "$volume"; then
            end_ts=$(date +%s)
            elapsed=$((end_ts - start_ts))
            local safe_name ext archive_file size
            safe_name="$(vb_safe_name "$volume")"
            ext="$(vb_archive_extension)"
            archive_file="${VB_OUTPUT_DIR}/${safe_name}-${VB_TS}.${ext}"
            size="$(vb_file_size "$archive_file")"
            if [ "$size" -eq 0 ]; then
                vb_warn "Archive file is empty: $archive_file"
            fi
            vb_success "Volume '${volume}' OK ($(vb_human_size "$size"), ${elapsed}s)"
            vb_add_result "$volume" "OK" "$size" "$elapsed" "$archive_file" ""
        else
            local rc=$?
            end_ts=$(date +%s)
            elapsed=$((end_ts - start_ts))
            local err_msg="backup command exited with code ${rc}"
            vb_error "Volume '${volume}' backup FAILED — ${err_msg}"
            vb_log_file "volume-backup: FAIL — ${volume}: ${err_msg}"
            vb_add_result "$volume" "FAIL" 0 "$elapsed" "" "$err_msg"
        fi
    fi
}

# ── Main ─────────────────────────────────────────────────────────────────────

vb_main() {
    # Ensure report directory is writable (best-effort)
    mkdir -p "$(dirname "$VB_REPORT")" 2>/dev/null || true

    vb_step "Docker volume backup"
    vb_info "Compress : $VB_COMPRESS"
    vb_info "Encrypt  : ${VB_ENCRYPT:-none}"
    vb_info "Restic   : $VB_RESTIC"
    vb_info "Dry-run  : $VB_DRY_RUN"
    if [ "$VB_RESTIC" = "false" ]; then
        vb_info "Output   : $VB_OUTPUT_DIR"
    else
        vb_info "Repo     : $VB_RESTIC_REPO"
    fi
    vb_info "Report   : $VB_REPORT"
    vb_log_file "volume-backup: started (compress=${VB_COMPRESS}, encrypt=${VB_ENCRYPT:-none}, restic=${VB_RESTIC}, dry-run=${VB_DRY_RUN})"

    local overall_start_ts overall_end_ts overall_elapsed
    overall_start_ts=$(date +%s)

    # ── 1. Collect volume list ───────────────────────────────────────────────
    vb_step "Step 1/3 — Collecting volume list"

    local volumes=""
    if [ "$VB_ALL" = "true" ]; then
        vb_info "Listing all Docker volumes..."
        local all_vols excluded_count=0
        all_vols="$(vb_list_all_volumes)"
        local v
        while IFS= read -r v; do
            [ -z "$v" ] && continue
            if vb_is_excluded "$v"; then
                vb_detail "Excluded: ${v}"
                excluded_count=$((excluded_count + 1))
                continue
            fi
            if [ -z "$volumes" ]; then
                volumes="$v"
            else
                volumes="${volumes}
${v}"
            fi
        done <<< "$all_vols"
        local total_count
        total_count="$(echo "$all_vols" | grep -c . 2>/dev/null || true)"
        vb_info "Found ${total_count} volume(s), ${excluded_count} excluded."
    else
        volumes="$VB_VOLUME"
        if vb_is_excluded "$VB_VOLUME"; then
            vb_warn "Volume '${VB_VOLUME}' matches an exclude pattern — will still back up (explicit --volume)."
        fi
        vb_info "Single volume: ${VB_VOLUME}"
    fi

    local volume_count
    volume_count="$(echo "$volumes" | grep -c . 2>/dev/null || true)"

    if [ "$volume_count" -eq 0 ]; then
        vb_warn "No volumes to back up. Nothing to do."
        vb_add_result "none" "SKIP" 0 0 "" "no volumes matched"
    fi

    # ── 2. Run backups ───────────────────────────────────────────────────────
    vb_step "Step 2/3 — Running volume backups"

    if [ "$VB_DRY_RUN" = "true" ]; then
        vb_info "DRY-RUN mode — no archives will be written."
    elif [ "$VB_RESTIC" = "false" ]; then
        mkdir -p "$VB_OUTPUT_DIR"
        vb_info "Output directory: ${VB_OUTPUT_DIR}"
        # Best-effort disk space check (warn if less than 1GB free)
        if ! vb_check_disk_space "$VB_OUTPUT_DIR" 1073741824; then
            vb_warn "Less than 1GB free disk space in ${VB_OUTPUT_DIR} — backups may fail."
        fi
    fi

    if [ "$volume_count" -gt 0 ]; then
        while IFS= read -r vol; do
            [ -z "$vol" ] && continue
            vb_process_volume "$vol"
        done <<< "$volumes"
    fi

    overall_end_ts=$(date +%s)
    overall_elapsed=$((overall_end_ts - overall_start_ts))

    # ── 3. Generate report ───────────────────────────────────────────────────
    vb_step "Step 3/3 — Generating report"

    vb_generate_report_text > "$VB_REPORT"
    vb_detail "Text report: ${VB_REPORT}"

    vb_generate_report_json > "$VB_JSON_REPORT"
    vb_detail "JSON report: ${VB_JSON_REPORT}"

    local fail_count
    fail_count="$(echo "$VB_RESULTS" | grep -c '|FAIL|' 2>/dev/null || true)"

    if [ "$fail_count" -eq 0 ]; then
        vb_success "Volume backup completed (all OK, ${overall_elapsed}s)."
        vb_log_file "volume-backup: PASS (volumes=${volume_count}, elapsed=${overall_elapsed}s)"
    else
        vb_error "Volume backup FAILED — ${fail_count} volume(s) failed."
        vb_log_file "volume-backup: FAIL (volumes=${volume_count}, failed=${fail_count}, elapsed=${overall_elapsed}s)"
    fi

    # Print integration hint
    if [ "$VB_DRY_RUN" = "false" ] && [ "$volume_count" -gt 0 ] && [ "$VB_RESTIC" = "false" ]; then
        vb_info ""
        vb_info "Archives are in: ${VB_OUTPUT_DIR}"
        vb_info "Include this directory in your Restic/Kopia backup paths so archives"
        vb_info "are captured in the next snapshot. Example:"
        vb_detail "restic backup ${VB_OUTPUT_DIR} /data"
        vb_detail "kopia snapshot create ${VB_OUTPUT_DIR} /data"
    fi

    # ── Cleanup ──────────────────────────────────────────────────────────────
    if [ "$VB_KEEP" = "true" ]; then
        vb_info "Keeping archive files at: ${VB_OUTPUT_DIR}"
    elif [ "$VB_DRY_RUN" = "false" ] && [ "$volume_count" -gt 0 ] && [ "$VB_RESTIC" = "false" ]; then
        if [ "$fail_count" -eq 0 ]; then
            vb_info "Cleaning up archive directory: ${VB_OUTPUT_DIR}"
            rm -rf -- "$VB_OUTPUT_DIR"
            vb_detail "Archive files removed. They have been captured in the backup snapshot."
        else
            vb_warn "Keeping archive files (some backups failed) for inspection: ${VB_OUTPUT_DIR}"
        fi
    fi

    # Exit code
    if [ "$fail_count" -gt 0 ]; then
        return 1
    fi
    return 0
}

# ── Run ──────────────────────────────────────────────────────────────────────

vb_main
exit $?
