#!/usr/bin/env bash
# scripts/restore-test.sh — Automated restore drill with checksum verification
#
# backup-kit: encrypted, automated, tested recovery for VPS and Docker.
# Homepage: https://github.com/0x10debug/backup-kit
#
# This script picks a snapshot from a Restic or Kopia repository, restores it
# to a temporary directory, and verifies file integrity by comparing SHA-256
# checksums between the source data and the restored copy. A text report is
# written at the end.
#
# Unlike `mb backup drill` (which runs a fresh backup first and compares file
# count + size), this script restores an *existing* snapshot and compares
# *checksums* — a deeper integrity check that catches silent bit-rot or
# partial corruption that size-only checks would miss.
#
# Usage:
#   restore-test.sh --backend restic [--snapshot auto|<ID>] [OPTIONS]
#   restore-test.sh --backend kopia  [--snapshot auto|<ID>] [OPTIONS]
#
# Options:
#   --backend restic|kopia   Backup backend to use (required)
#   --snapshot auto|<ID>     Snapshot to restore (default: auto = random pick)
#   --source PATH            Source data directory to compare against (default: /data)
#   --target PATH            Restore target directory (default: /tmp/mb-restore-test-<ts>)
#   --report PATH            Report file path (default: /var/lib/mb-backup/restore-test-<ts>.txt)
#   --strategy NAME          Strategy name for config lookup
#                            (restic: restic-s3|restic-sftp, kopia: kopia-s3)
#   --keep                   Keep the restored data after the drill (do not clean up)
#   --sample N               Only verify N randomly sampled files (0 = all, default: 0)
#   --help, -h               Show this help
#
# Exit codes:
#   0  Drill passed (all checksums match)
#   1  Drill failed (checksum mismatch or step failure)
#   2  Invalid arguments / missing prerequisites

set -euo pipefail

# ── Constants ────────────────────────────────────────────────────────────────

readonly RT_VERSION="1.0.0"
readonly RT_HOMEPAGE="https://github.com/0x10debug/backup-kit"

# ── Defaults ─────────────────────────────────────────────────────────────────

RT_BACKEND=""
RT_SNAPSHOT="auto"
RT_SOURCE="${MB_DATA_DIR:-/data}"
RT_TARGET=""
RT_REPORT=""
RT_STRATEGY=""
RT_KEEP=false
RT_SAMPLE=0

# Resolved at runtime
RT_CONFIG_DIR="${MB_CONFIG_DIR:-/etc/mb-backup}"
RT_STATE_DIR="${MB_STATE_DIR:-/var/lib/mb-backup}"
RT_LOG_FILE="${MB_LOG_FILE:-/var/log/mb-backup.log}"

# ── Logging helpers (self-contained, no external deps) ───────────────────────

rt_log() {
    local level="$1"; shift
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    printf '[%s] %s %s\n' "$ts" "$level" "$*"
}

rt_info()    { rt_log "INFO" "$*" >&2; }
rt_success() { rt_log "OK"   "$*" >&2; }
rt_warn()    { rt_log "WARN" "$*" >&2; }
rt_error()   { rt_log "ERROR" "$*" >&2; }
rt_step()    { printf '\n==> %s\n' "$*" >&2; }
rt_detail()  { printf '    %s\n' "$*" >&2; }

rt_log_file() {
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    ( mkdir -p "$(dirname "$RT_LOG_FILE")" 2>/dev/null
      echo "[${ts}] $*" >> "$RT_LOG_FILE" ) 2>/dev/null || true
}

rt_die() {
    rt_error "$*"
    rt_log_file "restore-test: FATAL: $*"
    exit 2
}

# ── Argument parsing ─────────────────────────────────────────────────────────

rt_show_help() {
    cat <<'HELP'
restore-test.sh — Automated restore drill with checksum verification

Usage:
  restore-test.sh --backend restic [--snapshot auto|<ID>] [OPTIONS]
  restore-test.sh --backend kopia  [--snapshot auto|<ID>] [OPTIONS]

Options:
  --backend restic|kopia   Backup backend to use (required)
  --snapshot auto|<ID>     Snapshot to restore (default: auto = random pick)
  --source PATH            Source data directory to compare against (default: /data)
  --target PATH            Restore target directory (default: /tmp/mb-restore-test-<ts>)
  --report PATH            Report file path (default: /var/lib/mb-backup/restore-test-<ts>.txt)
  --strategy NAME          Strategy name for config lookup
                           (restic: restic-s3|restic-sftp, kopia: kopia-s3)
  --keep                   Keep the restored data after the drill
  --sample N               Only verify N randomly sampled files (0 = all, default: 0)
  --help, -h               Show this help

Homepage: https://github.com/0x10debug/backup-kit
HELP
}

while [ $# -gt 0 ]; do
    case "$1" in
        --backend)  RT_BACKEND="$2"; shift 2 ;;
        --snapshot) RT_SNAPSHOT="$2"; shift 2 ;;
        --source)   RT_SOURCE="$2"; shift 2 ;;
        --target)   RT_TARGET="$2"; shift 2 ;;
        --report)   RT_REPORT="$2"; shift 2 ;;
        --strategy) RT_STRATEGY="$2"; shift 2 ;;
        --keep)     RT_KEEP=true; shift ;;
        --sample)   RT_SAMPLE="$2"; shift 2 ;;
        --version)  echo "restore-test.sh ${RT_VERSION} (${RT_HOMEPAGE})"; exit 0 ;;
        --help|-h)  rt_show_help; exit 0 ;;
        *) rt_error "Unknown option: $1"; rt_show_help; exit 2 ;;
    esac
done

# ── Validation ───────────────────────────────────────────────────────────────

if [ -z "$RT_BACKEND" ]; then
    rt_error "--backend is required (restic or kopia)."
    rt_show_help
    exit 2
fi

case "$RT_BACKEND" in
    restic|kopia) ;;
    *) rt_error "Unsupported backend: $RT_BACKEND (use 'restic' or 'kopia')."; exit 2 ;;
esac

# Resolve strategy name if not provided
if [ -z "$RT_STRATEGY" ]; then
    case "$RT_BACKEND" in
        restic)
            # Prefer restic-s3, fall back to restic-sftp if that's what's configured
            if [ -f "${RT_CONFIG_DIR}/restic-s3/.env" ]; then
                RT_STRATEGY="restic-s3"
            elif [ -f "${RT_CONFIG_DIR}/restic-sftp/.env" ]; then
                RT_STRATEGY="restic-sftp"
            else
                RT_STRATEGY="restic-s3"
            fi
            ;;
        kopia) RT_STRATEGY="kopia-s3" ;;
    esac
fi

# Timestamp for default paths
RT_TS="$(date '+%Y%m%d-%H%M%S')"
if [ -z "$RT_TARGET" ]; then
    RT_TARGET="/tmp/mb-restore-test-${RT_TS}"
fi
if [ -z "$RT_REPORT" ]; then
    RT_REPORT="${RT_STATE_DIR}/restore-test-${RT_TS}.txt"
fi

# ── Prerequisite checks ──────────────────────────────────────────────────────

rt_check_command() {
    command -v "$1" >/dev/null 2>&1
}

# Detect a working SHA-256 tool: prefer sha256sum (Linux), fall back to shasum (macOS/BSD)
rt_detect_sha256() {
    if rt_check_command sha256sum; then
        RT_SHA256_CMD="sha256sum"
    elif rt_check_command shasum; then
        RT_SHA256_CMD="shasum -a 256"
    else
        rt_error "No SHA-256 tool found (need sha256sum or shasum)."
        exit 2
    fi
}

rt_detect_sha256

case "$RT_BACKEND" in
    restic)
        rt_check_command restic || rt_die "restic is not installed."
        ;;
    kopia)
        rt_check_command kopia || rt_die "kopia is not installed."
        ;;
esac

# ── Load strategy environment ────────────────────────────────────────────────

# Try strategy directory in the repo first, then deployed config
rt_find_env_file() {
    local strategy="$1"
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    local candidates=(
        "${script_dir}/strategies/${strategy}/.env"
        "${RT_CONFIG_DIR}/${strategy}/.env"
    )
    for f in "${candidates[@]}"; do
        if [ -f "$f" ]; then
            echo "$f"
            return 0
        fi
    done
    return 1
}

RT_ENV_FILE=""
RT_ENV_FILE="$(rt_find_env_file "$RT_STRATEGY")" || {
    rt_error "No .env found for strategy '${RT_STRATEGY}'."
    rt_detail "Run 'mb backup init' first, or create ${RT_CONFIG_DIR}/${RT_STRATEGY}/.env"
    exit 2
}

# shellcheck disable=SC1090
source "$RT_ENV_FILE"

rt_info "Loaded config: ${RT_ENV_FILE}"

# Validate backend-specific env vars
case "$RT_BACKEND" in
    restic)
        : "${RESTIC_REPOSITORY:?RESTIC_REPOSITORY must be set in .env}"
        : "${RESTIC_PASSWORD:?RESTIC_PASSWORD must be set in .env}"
        export RESTIC_REPOSITORY RESTIC_PASSWORD
        if [ -n "${AWS_ACCESS_KEY_ID:-}" ] && [ -n "${AWS_SECRET_ACCESS_KEY:-}" ]; then
            export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
        fi
        ;;
    kopia)
        : "${KOPIA_REPOSITORY:?KOPIA_REPOSITORY must be set in .env}"
        : "${KOPIA_PASSWORD:?KOPIA_PASSWORD must be set in .env}"
        : "${AWS_ACCESS_KEY_ID:?AWS_ACCESS_KEY_ID must be set in .env}"
        : "${AWS_SECRET_ACCESS_KEY:?AWS_SECRET_ACCESS_KEY must be set in .env}"
        export KOPIA_PASSWORD AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
        ;;
esac

# ── Core functions ───────────────────────────────────────────────────────────

# Echo all snapshot IDs, one per line.
rt_list_snapshots() {
    case "$RT_BACKEND" in
        restic)
            # Output format: ID Date Host Tags Paths
            restic snapshots --compact 2>/dev/null | awk 'NR>2 && /^[a-f0-9]{8,}/ {print $1}'
            ;;
        kopia)
            # Kopia snapshot list --all shows manifests; extract root IDs
            kopia snapshot list --all --json 2>/dev/null \
                | grep -o '"rootID":"[^"]*"' | cut -d'"' -f4
            ;;
    esac
}

# Restore a specific snapshot ID to the target directory.
rt_restore_snapshot() {
    local snap_id="$1" target="$2"
    case "$RT_BACKEND" in
        restic)
            restic restore "$snap_id" --target "$target"
            ;;
        kopia)
            kopia snapshot restore "$snap_id" "$target"
            ;;
    esac
}

# Compute SHA-256 of a file, echo only the digest.
rt_checksum() {
    local file="$1"
    # shellcheck disable=SC2086
    $RT_SHA256_CMD "$file" 2>/dev/null | awk '{print $1}'
}

# Find the data root inside the restore target.
# Restic restores with full original absolute paths (e.g. /data → target/data/...).
# Kopia restores the snapshot root directly into target.
# We try several candidate locations and pick the first that exists.
rt_find_data_root() {
    local target="$1" source="$2"
    local base abs_source

    # Normalise source to an absolute path for the restic case
    if [[ "$source" = /* ]]; then
        abs_source="$source"
    else
        abs_source="$(cd "$source" 2>/dev/null && pwd)"
    fi
    base="$(basename "$source")"

    # Candidate locations, in order of preference:
    # 1. target + absolute source path (restic with absolute paths)
    # 2. target + basename of source (restic with relative paths, or kopia)
    # 3. target itself (kopia restores root into target)
    local candidates=(
        "${target}${abs_source}"
        "${target}/${base}"
        "${target}"
    )

    for c in "${candidates[@]}"; do
        if [ -d "$c" ]; then
            echo "$c"
            return 0
        fi
    done
    echo ""
    return 1
}

# List regular files relative to a root directory, sorted, one per line.
rt_list_files_relative() {
    local root="$1"
    if [ -d "$root" ]; then
        find "$root" -type f 2>/dev/null \
            | sed "s|^${root}/||" \
            | sort
    fi
}

# ── Main drill logic ─────────────────────────────────────────────────────────

rt_run_drill() {
    # Ensure the report directory is writable (best-effort, not fatal)
    mkdir -p "$(dirname "$RT_REPORT")" 2>/dev/null || true

    rt_step "Starting restore drill (checksum verification)"
    rt_info "Backend  : $RT_BACKEND"
    rt_info "Strategy : $RT_STRATEGY"
    rt_info "Source   : $RT_SOURCE"
    rt_info "Target   : $RT_TARGET"
    rt_info "Report   : $RT_REPORT"
    rt_info "Snapshot : $RT_SNAPSHOT"
    rt_log_file "restore-test: started (backend=${RT_BACKEND}, strategy=${RT_STRATEGY})"

    local start_ts end_ts elapsed
    start_ts=$(date +%s)

    # ── 1. List and pick a snapshot ──────────────────────────────────────────
    rt_step "Step 1/5 — Selecting snapshot"

    if [ ! -d "$RT_SOURCE" ]; then
        rt_error "Source directory does not exist: $RT_SOURCE"
        rt_log_file "restore-test: FAIL — source directory missing"
        exit 1
    fi

    local snapshots selected_snapshot
    snapshots="$(rt_list_snapshots)"
    local snap_count
    snap_count=$(echo "$snapshots" | grep -c . 2>/dev/null || true)

    if [ "$snap_count" -eq 0 ]; then
        rt_error "No snapshots found in the repository."
        rt_detail "Run 'mb backup run' to create a backup first."
        rt_log_file "restore-test: FAIL — no snapshots in repository"
        exit 1
    fi
    rt_info "Found ${snap_count} snapshot(s)."

    if [ "$RT_SNAPSHOT" = "auto" ]; then
        # Pick a random snapshot
        local idx
        if [ "$snap_count" -eq 1 ]; then
            selected_snapshot="$(echo "$snapshots" | head -1)"
        else
            # Random line from the list
            idx=$(( RANDOM % snap_count + 1 ))
            selected_snapshot="$(echo "$snapshots" | sed -n "${idx}p")"
        fi
        rt_info "Auto-selected snapshot: ${selected_snapshot}"
    else
        selected_snapshot="$RT_SNAPSHOT"
        # Verify the snapshot exists
        if ! echo "$snapshots" | grep -qx "$selected_snapshot"; then
            rt_warn "Snapshot '${selected_snapshot}' not found in snapshot list."
            rt_detail "Proceeding anyway — it may be a valid ID not captured by the listing."
        fi
        rt_info "Using specified snapshot: ${selected_snapshot}"
    fi

    # ── 2. Restore to target ─────────────────────────────────────────────────
    rt_step "Step 2/5 — Restoring snapshot to ${RT_TARGET}"

    mkdir -p "$RT_TARGET"
    if ! rt_restore_snapshot "$selected_snapshot" "$RT_TARGET"; then
        rt_error "Restore step failed."
        rt_log_file "restore-test: FAIL — restore step failed"
        rt_cleanup
        exit 1
    fi
    rt_success "Restore completed."

    # ── 3. Locate restored data root ─────────────────────────────────────────
    rt_step "Step 3/5 — Locating restored data"

    local data_root
    data_root="$(rt_find_data_root "$RT_TARGET" "$RT_SOURCE")"
    if [ -z "$data_root" ] || [ ! -d "$data_root" ]; then
        rt_error "Could not locate restored data under ${RT_TARGET}."
        rt_detail "Expected data at ${RT_TARGET}/$(basename "$RT_SOURCE") or directly under ${RT_TARGET}"
        rt_log_file "restore-test: FAIL — restored data root not found"
        rt_cleanup
        exit 1
    fi
    rt_info "Restored data root: ${data_root}"

    # ── 4. Compare checksums ─────────────────────────────────────────────────
    rt_step "Step 4/5 — Verifying file integrity (SHA-256 checksums)"

    local src_files dst_files
    src_files="$(rt_list_files_relative "$RT_SOURCE")"
    dst_files="$(rt_list_files_relative "$data_root")"

    local src_count dst_count
    src_count=$(echo "$src_files" | grep -c . 2>/dev/null || true)
    dst_count=$(echo "$dst_files" | grep -c . 2>/dev/null || true)

    rt_info "Source files   : ${src_count}"
    rt_info "Restored files : ${dst_count}"

    # Check for file list mismatches
    local missing_files extra_files
    missing_files="$(comm -23 <(echo "$src_files") <(echo "$dst_files"))"
    extra_files="$(comm -13 <(echo "$src_files") <(echo "$dst_files"))"
    local missing_count extra_count
    missing_count=$(echo "$missing_files" | grep -c . 2>/dev/null || true)
    extra_count=$(echo "$extra_files" | grep -c . 2>/dev/null || true)

    if [ "$missing_count" -gt 0 ]; then
        rt_warn "${missing_count} file(s) missing in restored data:"
        echo "$missing_files" | head -10 | while IFS= read -r f; do
            rt_detail "  missing: $f"
        done
        if [ "$missing_count" -gt 10 ]; then
            rt_detail "  ... and $((missing_count - 10)) more"
        fi
    fi

    if [ "$extra_count" -gt 0 ]; then
        rt_warn "${extra_count} extra file(s) in restored data:"
        echo "$extra_files" | head -10 | while IFS= read -r f; do
            rt_detail "  extra: $f"
        done
        if [ "$extra_count" -gt 10 ]; then
            rt_detail "  ... and $((extra_count - 10)) more"
        fi
    fi

    # Determine which files to checksum
    local files_to_check
    if [ "$RT_SAMPLE" -gt 0 ] && [ "$src_count" -gt "$RT_SAMPLE" ]; then
        # Randomly sample N files from the source list
        files_to_check="$(echo "$src_files" | shuf --random-source=/dev/urandom -n "$RT_SAMPLE" 2>/dev/null || echo "$src_files" | awk -v n="$RT_SAMPLE" 'BEGIN{srand()} {print rand(), $0}' | sort -n | head -n "$RT_SAMPLE" | cut -d' ' -f2-)"
        rt_info "Sampling ${RT_SAMPLE} of ${src_count} files for checksum verification."
    else
        files_to_check="$src_files"
        rt_info "Verifying checksums for all ${src_count} file(s)."
    fi

    # Compare checksums
    local checked=0 mismatches=0
    local mismatch_list=""
    while IFS= read -r relpath; do
        [ -z "$relpath" ] && continue
        local src_cksum dst_cksum
        src_cksum="$(rt_checksum "${RT_SOURCE}/${relpath}")"
        dst_cksum="$(rt_checksum "${data_root}/${relpath}")"
        checked=$((checked + 1))
        if [ "$src_cksum" != "$dst_cksum" ]; then
            mismatches=$((mismatches + 1))
            if [ "$mismatches" -le 10 ]; then
                mismatch_list="${mismatch_list}\n  ${relpath}\n    source: ${src_cksum}\n    restored: ${dst_cksum}"
            fi
        fi
        # Progress indicator every 500 files
        if [ $((checked % 500)) -eq 0 ]; then
            rt_detail "  ... checked ${checked} files, ${mismatches} mismatch(es) so far"
        fi
    done <<< "$files_to_check"

    rt_info "Checksums compared: ${checked}"
    rt_info "Mismatches: ${mismatches}"

    end_ts=$(date +%s)
    elapsed=$((end_ts - start_ts))

    # ── Determine verdict ────────────────────────────────────────────────────
    local verdict="PASS" reason=""

    if [ "$missing_count" -gt 0 ]; then
        verdict="FAIL"
        reason="${reason:+${reason}; }${missing_count} file(s) missing in restore"
    fi
    if [ "$extra_count" -gt 0 ]; then
        if [ "$verdict" != "FAIL" ]; then verdict="WARN"; fi
        reason="${reason:+${reason}; }${extra_count} extra file(s) in restore"
    fi
    if [ "$mismatches" -gt 0 ]; then
        verdict="FAIL"
        reason="${reason:+${reason}; }${mismatches} checksum mismatch(es)"
    fi
    if [ "$src_count" -eq 0 ]; then
        verdict="WARN"
        reason="${reason:+${reason}; }source directory is empty"
    fi

    # ── 5. Generate report ───────────────────────────────────────────────────
    rt_step "Step 5/5 — Generating report"

    {
        echo "=========================================="
        echo " backup-kit Restore Test Report"
        echo "=========================================="
        echo "Date       : $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Backend    : ${RT_BACKEND}"
        echo "Strategy   : ${RT_STRATEGY}"
        echo "Snapshot   : ${selected_snapshot}"
        echo "Source     : ${RT_SOURCE}"
        echo "Data root  : ${data_root}"
        echo "Target     : ${RT_TARGET}"
        echo "Duration   : ${elapsed}s"
        echo ""
        echo "---- File counts ----"
        echo "Source files     : ${src_count}"
        echo "Restored files   : ${dst_count}"
        echo "Missing files    : ${missing_count}"
        echo "Extra files      : ${extra_count}"
        echo ""
        echo "---- Checksum verification ----"
        echo "Algorithm        : SHA-256"
        echo "Files checked    : ${checked}"
        if [ "$RT_SAMPLE" -gt 0 ] && [ "$src_count" -gt "$RT_SAMPLE" ]; then
            echo "Sampling         : ${RT_SAMPLE} of ${src_count} (random)"
        else
            echo "Sampling         : full (all files)"
        fi
        echo "Mismatches       : ${mismatches}"
        if [ "$mismatches" -gt 0 ]; then
            echo ""
            echo "---- Mismatched files (up to 10) ----"
            echo -e "$mismatch_list"
        fi
        echo ""
        echo "---- Verdict ----"
        echo "Result           : ${verdict}"
        if [ -n "$reason" ]; then
            echo "Reason           : ${reason}"
        fi
        echo ""
        echo "A backup you have never tested is just a hope, not a backup."
        echo "=========================================="
    } > "$RT_REPORT"
    rt_detail "Report written to ${RT_REPORT}"

    if [ "$verdict" = "PASS" ]; then
        rt_success "Restore test PASSED — all checksums match."
        rt_log_file "restore-test: PASS (checked=${checked}, mismatches=0)"
    elif [ "$verdict" = "WARN" ]; then
        rt_warn "Restore test completed with WARNINGS — ${reason}"
        rt_log_file "restore-test: WARN (${reason})"
    else
        rt_error "Restore test FAILED — ${reason}"
        rt_log_file "restore-test: FAIL (${reason})"
    fi

    # ── Cleanup ──────────────────────────────────────────────────────────────
    rt_cleanup

    if [ "$verdict" = "PASS" ]; then
        return 0
    elif [ "$verdict" = "WARN" ]; then
        return 0
    else
        return 1
    fi
}

rt_cleanup() {
    if [ "$RT_KEEP" = "true" ]; then
        rt_info "Keeping restored data at: ${RT_TARGET}"
        return 0
    fi
    if [ -n "$RT_TARGET" ] && [ -d "$RT_TARGET" ]; then
        rm -rf -- "$RT_TARGET"
        rt_detail "Cleaned up ${RT_TARGET}"
    fi
}

# ── Run ──────────────────────────────────────────────────────────────────────

rt_run_drill
exit $?
