#!/usr/bin/env bash
# scripts/backend-migrate.sh — Migrate Restic snapshots between backends
#
# backup-kit: encrypted, automated, tested recovery for VPS and Docker.
# Homepage: https://github.com/0x10debug/backup-kit
#
# Wraps `restic copy` to migrate snapshots from one Restic repository to
# another (e.g. AWS S3 → Wasabi, Wasabi → MinIO, B2 → S3). restic copy reads
# each snapshot from the source repo and writes its deduplicated blobs to the
# destination; data already present in the destination is skipped, so re-runs
# are cheap and the script is safe to interrupt and resume.
#
# The source and destination repos are described by env files (the same
# *.env.example templates used by the restic-s3 strategy, filled in with real
# credentials). The script sources them in subshells so credentials never
# leak into the parent environment or logs.
#
# Usage:
#   backend-migrate.sh --from-env FILE --to-env FILE [OPTIONS]
#
# Options:
#   --from-env FILE        Source repo env file (required)
#   --to-env FILE          Destination repo env file (required)
#   --snapshot ID          Copy only the given snapshot ID (repeatable)
#   --tag TAG              Copy only snapshots with this tag (repeatable)
#   --path PATH            Copy only snapshots for this backup path (repeatable)
#   --host HOST            Copy only snapshots made on this host (repeatable)
#   --dry-run              Preview what would be copied; no data is written
#   --no-verify            Skip the destination `restic check` after copying
#   --init                 Initialize the destination repo if it does not exist
#   --report PATH          Write a migration report to PATH
#                          (default: /var/lib/mb-backup/backend-migrate-<ts>.txt)
#   --help, -h             Show this help
#
# Exit codes:
#   0  Migration completed (or dry-run previewed) successfully
#   1  Migration failed (copy or verification step failed)
#   2  Invalid arguments / missing prerequisites
#
# Notes:
#   * The destination repo MUST be initialized (restic init) before copying,
#     unless --init is given. The source and destination may use different
#     RESTIC_PASSWORD values; restic copy reads the source password from
#     RESTIC_PASSWORD (or --from-password-file) and the destination from
#     RESTIC_PASSWORD (or --password-file). When both env files set
#     RESTIC_PASSWORD, this script passes the source password via
#     --from-password-file (a temp file) and the destination via the env, so
#     differing passwords are supported.
#   * restic copy requires restic >= 0.12.0.

set -euo pipefail

# ── Constants ────────────────────────────────────────────────────────────────

readonly BM_VERSION="1.0.0"
readonly BM_HOMEPAGE="https://github.com/0x10debug/backup-kit"

# ── Defaults ─────────────────────────────────────────────────────────────────

BM_FROM_ENV=""
BM_TO_ENV=""
BM_SNAPSHOTS=()
BM_TAGS=()
BM_PATHS=()
BM_HOSTS=()
BM_DRY_RUN=false
BM_VERIFY=true
BM_INIT=false
BM_REPORT=""

# Resolved at runtime
BM_STATE_DIR="${MB_STATE_DIR:-/var/lib/mb-backup}"
BM_LOG_FILE="${MB_LOG_FILE:-/var/log/mb-backup.log}"

# Temp files cleaned up on exit
BM_FROM_PW_FILE=""
BM_CLEANUP_FILES=()

# ── Logging helpers (self-contained, no external deps) ───────────────────────

bm_log() {
    local level="$1"; shift
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    printf '[%s] %s %s\n' "$ts" "$level" "$*"
}

bm_info()    { bm_log "INFO" "$*" >&2; }
bm_success() { bm_log "OK"   "$*" >&2; }
bm_warn()    { bm_log "WARN" "$*" >&2; }
bm_error()   { bm_log "ERROR" "$*" >&2; }
bm_step()    { printf '\n==> %s\n' "$*" >&2; }
bm_detail()  { printf '    %s\n' "$*" >&2; }

bm_log_file() {
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    ( mkdir -p "$(dirname "$BM_LOG_FILE")" 2>/dev/null
      echo "[${ts}] $*" >> "$BM_LOG_FILE" ) 2>/dev/null || true
}

bm_die() {
    bm_error "$*"
    bm_log_file "backend-migrate: FATAL: $*"
    exit 2
}

# ── Cleanup ──────────────────────────────────────────────────────────────────

bm_cleanup() {
    local f
    for f in "${BM_CLEANUP_FILES[@]:-}"; do
        [ -n "$f" ] && rm -f "$f" 2>/dev/null || true
    done
}
trap bm_cleanup EXIT

# ── Argument parsing ─────────────────────────────────────────────────────────

bm_show_help() {
    cat <<'HELP'
backend-migrate.sh — Migrate Restic snapshots between backends (restic copy)

Usage:
  backend-migrate.sh --from-env FILE --to-env FILE [OPTIONS]

Options:
  --from-env FILE        Source repo env file (required)
  --to-env FILE          Destination repo env file (required)
  --snapshot ID          Copy only the given snapshot ID (repeatable)
  --tag TAG              Copy only snapshots with this tag (repeatable)
  --path PATH            Copy only snapshots for this backup path (repeatable)
  --host HOST            Copy only snapshots made on this host (repeatable)
  --dry-run              Preview what would be copied; no data is written
  --no-verify            Skip the destination `restic check` after copying
  --init                 Initialize the destination repo if it does not exist
  --report PATH          Write a migration report to PATH
                         (default: /var/lib/mb-backup/backend-migrate-<ts>.txt)
  --help, -h             Show this help

Homepage: https://github.com/0x10debug/backup-kit
HELP
}

while [ $# -gt 0 ]; do
    case "$1" in
        --from-env)  BM_FROM_ENV="$2"; shift 2 ;;
        --to-env)    BM_TO_ENV="$2"; shift 2 ;;
        --snapshot)  BM_SNAPSHOTS+=("$2"); shift 2 ;;
        --tag)       BM_TAGS+=("$2"); shift 2 ;;
        --path)      BM_PATHS+=("$2"); shift 2 ;;
        --host)      BM_HOSTS+=("$2"); shift 2 ;;
        --dry-run)   BM_DRY_RUN=true; shift ;;
        --no-verify) BM_VERIFY=false; shift ;;
        --init)      BM_INIT=true; shift ;;
        --report)    BM_REPORT="$2"; shift 2 ;;
        --version)   echo "backend-migrate.sh ${BM_VERSION} (${BM_HOMEPAGE})"; exit 0 ;;
        --help|-h)   bm_show_help; exit 0 ;;
        *) bm_error "Unknown option: $1"; bm_show_help; exit 2 ;;
    esac
done

# ── Validation ───────────────────────────────────────────────────────────────

if [ -z "$BM_FROM_ENV" ] || [ -z "$BM_TO_ENV" ]; then
    bm_error "Both --from-env and --to-env are required."
    bm_show_help
    exit 2
fi

[ -f "$BM_FROM_ENV" ] || bm_die "Source env file not found: $BM_FROM_ENV"
[ -f "$BM_TO_ENV" ]   || bm_die "Destination env file not found: $BM_TO_ENV"

command -v restic >/dev/null 2>&1 || bm_die "restic is not installed (need >= 0.12.0 for 'restic copy')."

# Timestamp for default report path
BM_TS="$(date '+%Y%m%d-%H%M%S')"
if [ -z "$BM_REPORT" ]; then
    BM_REPORT="${BM_STATE_DIR}/backend-migrate-${BM_TS}.txt"
fi

# ── Load repo envs in subshells and extract the values we need ───────────────
# We must keep source and destination credentials separate because restic copy
# talks to both repos in one invocation. Strategy:
#   * Destination credentials are exported in the parent (restic uses them for
#     the destination repo).
#   * Source credentials are passed via RESTIC_REPOSITORY_FROM-* env vars and
#     the source password via --from-password-file (a temp file), so a
#     different source password is supported.

# Extract a single variable from an env file without polluting the parent env.
bm_env_value() {
    local envfile="$1" key="$2"
    # shellcheck disable=SC1090
    ( set -a; source "$envfile" 2>/dev/null; printf '%s' "${!key:-}" )
}

# ── Destination credentials (exported in parent) ─────────────────────────────

DEST_REPO="$(bm_env_value "$BM_TO_ENV" RESTIC_REPOSITORY)"
DEST_PW="$(bm_env_value "$BM_TO_ENV" RESTIC_PASSWORD)"
DEST_AK="$(bm_env_value "$BM_TO_ENV" AWS_ACCESS_KEY_ID)"
DEST_SK="$(bm_env_value "$BM_TO_ENV" AWS_SECRET_ACCESS_KEY)"
DEST_B2_ID="$(bm_env_value "$BM_TO_ENV" B2_ACCOUNT_ID)"
DEST_B2_KEY="$(bm_env_value "$BM_TO_ENV" B2_ACCOUNT_KEY)"
DEST_CA="$(bm_env_value "$BM_TO_ENV" AWS_CA_BUNDLE)"

[ -n "$DEST_REPO" ] || bm_die "Destination env is missing RESTIC_REPOSITORY: $BM_TO_ENV"
[ -n "$DEST_PW" ]   || bm_die "Destination env is missing RESTIC_PASSWORD: $BM_TO_ENV"

export RESTIC_REPOSITORY="$DEST_REPO"
export RESTIC_PASSWORD="$DEST_PW"
[ -n "$DEST_AK" ]  && export AWS_ACCESS_KEY_ID="$DEST_AK"
[ -n "$DEST_SK" ]  && export AWS_SECRET_ACCESS_KEY="$DEST_SK"
[ -n "$DEST_B2_ID" ]  && export B2_ACCOUNT_ID="$DEST_B2_ID"
[ -n "$DEST_B2_KEY" ] && export B2_ACCOUNT_KEY="$DEST_B2_KEY"
[ -n "$DEST_CA" ]  && export AWS_CA_BUNDLE="$DEST_CA"

# ── Source credentials (passed via FROM-* env + temp password file) ──────────

SRC_REPO="$(bm_env_value "$BM_FROM_ENV" RESTIC_REPOSITORY)"
SRC_PW="$(bm_env_value "$BM_FROM_ENV" RESTIC_PASSWORD)"
SRC_AK="$(bm_env_value "$BM_FROM_ENV" AWS_ACCESS_KEY_ID)"
SRC_SK="$(bm_env_value "$BM_FROM_ENV" AWS_SECRET_ACCESS_KEY)"
SRC_B2_ID="$(bm_env_value "$BM_FROM_ENV" B2_ACCOUNT_ID)"
SRC_B2_KEY="$(bm_env_value "$BM_FROM_ENV" B2_ACCOUNT_KEY)"
SRC_CA="$(bm_env_value "$BM_FROM_ENV" AWS_CA_BUNDLE)"

[ -n "$SRC_REPO" ] || bm_die "Source env is missing RESTIC_REPOSITORY: $BM_FROM_ENV"
[ -n "$SRC_PW" ]   || bm_die "Source env is missing RESTIC_PASSWORD: $BM_FROM_ENV"

export RESTIC_REPOSITORY_FROM="$SRC_REPO"
[ -n "$SRC_AK" ]  && export AWS_ACCESS_KEY_ID_FROM="$SRC_AK"
[ -n "$SRC_SK" ]  && export AWS_SECRET_ACCESS_KEY_FROM="$SRC_SK"
[ -n "$SRC_B2_ID" ]  && export B2_ACCOUNT_ID_FROM="$SRC_B2_ID"
[ -n "$SRC_B2_KEY" ] && export B2_ACCOUNT_KEY_FROM="$SRC_B2_KEY"
[ -n "$SRC_CA" ]  && export AWS_CA_BUNDLE_FROM="$SRC_CA"

# Write the source password to a temp file for --from-password-file.
BM_FROM_PW_FILE="$(mktemp -t bm-from-pw.XXXXXX)"
chmod 600 "$BM_FROM_PW_FILE"
printf '%s' "$SRC_PW" > "$BM_FROM_PW_FILE"
BM_CLEANUP_FILES+=("$BM_FROM_PW_FILE")

# ── Report writer ────────────────────────────────────────────────────────────

bm_report_line() {
    ( mkdir -p "$(dirname "$BM_REPORT")" 2>/dev/null
      echo "$*" >> "$BM_REPORT" ) 2>/dev/null || true
}

{
    echo "mb-backup backend-migrate report"
    echo "Date        : $(date '+%Y-%m-%d %H:%M:%S')"
    echo "Source      : ${BM_FROM_ENV} (${SRC_REPO})"
    echo "Destination : ${BM_TO_ENV} (${DEST_REPO})"
    echo "Dry-run     : ${BM_DRY_RUN}"
    echo "Init dest   : ${BM_INIT}"
    echo "Verify      : ${BM_VERIFY}"
    echo "-----------------------------------------------"
} > "$BM_REPORT" 2>/dev/null || true

# ── Step 1: optionally initialize the destination repo ───────────────────────

bm_step "Step 1: Prepare destination repository"

if $BM_INIT; then
    if restic snapshots >/dev/null 2>&1; then
        bm_info "Destination repo already initialized — skipping init."
        bm_report_line "init: destination already initialized (skipped)"
    else
        bm_info "Initializing destination repo: ${DEST_REPO}"
        if $BM_DRY_RUN; then
            bm_detail "[dry-run] would run: restic init"
            bm_report_line "init: [dry-run] skipped restic init"
        else
            if restic init; then
                bm_success "Destination repo initialized."
                bm_report_line "init: OK"
            else
                bm_error "restic init failed for destination."
                bm_report_line "init: FAILED"
                exit 1
            fi
        fi
    fi
else
    if ! restic snapshots >/dev/null 2>&1; then
        bm_die "Destination repo is not initialized. Re-run with --init, or run 'restic init' against it first."
    fi
    bm_info "Destination repo is initialized and reachable."
    bm_report_line "init: destination reachable (no --init given)"
fi

# ── Step 2: list source snapshots (preview) ──────────────────────────────────

bm_step "Step 2: List source snapshots"

# Build the restic copy filter args (snapshot/tag/path/host selectors).
COPY_FILTER_ARGS=()
for s in "${BM_SNAPSHOTS[@]:-}"; do
    [ -n "$s" ] && COPY_FILTER_ARGS+=("$s")
done
for t in "${BM_TAGS[@]:-}"; do
    [ -n "$t" ] && COPY_FILTER_ARGS+=(--tag "$t")
done
for p in "${BM_PATHS[@]:-}"; do
    [ -n "$p" ] && COPY_FILTER_ARGS+=(--path "$p")
done
for h in "${BM_HOSTS[@]:-}"; do
    [ -n "$h" ] && COPY_FILTER_ARGS+=(--host "$h")
done

# Count source snapshots matching the filter (for progress reporting).
# restic snapshots --json gives one JSON object per line per snapshot.
SRC_COUNT=0
if SRC_LIST_OUTPUT="$(RESTIC_REPOSITORY="$SRC_REPO" \
        AWS_ACCESS_KEY_ID="$SRC_AK" AWS_SECRET_ACCESS_KEY="$SRC_SK" \
        B2_ACCOUNT_ID="$SRC_B2_ID" B2_ACCOUNT_KEY="$SRC_B2_KEY" \
        AWS_CA_BUNDLE="$SRC_CA" \
        RESTIC_PASSWORD_FILE="$BM_FROM_PW_FILE" \
        restic snapshots --json "${COPY_FILTER_ARGS[@]}" 2>/dev/null)"; then
    SRC_COUNT="$(printf '%s\n' "$SRC_LIST_OUTPUT" | grep -c '"short_id"' || true)"
fi

if [ "$SRC_COUNT" -eq 0 ]; then
    bm_warn "No snapshots found in the source matching the given filters."
    bm_report_line "source-snapshots: 0 (no match)"
    bm_success "Nothing to copy. Done."
    exit 0
fi

bm_info "Source snapshots to copy: ${SRC_COUNT}"
bm_report_line "source-snapshots: ${SRC_COUNT}"

if $BM_DRY_RUN; then
    bm_detail "[dry-run] would run: restic copy --from-repo <source> ${COPY_FILTER_ARGS[*]}"
    # Still show the snapshot list for preview.
    RESTIC_REPOSITORY="$SRC_REPO" \
        AWS_ACCESS_KEY_ID="$SRC_AK" AWS_SECRET_ACCESS_KEY="$SRC_SK" \
        B2_ACCOUNT_ID="$SRC_B2_ID" B2_ACCOUNT_KEY="$SRC_B2_KEY" \
        AWS_CA_BUNDLE="$SRC_CA" \
        RESTIC_PASSWORD_FILE="$BM_FROM_PW_FILE" \
        restic snapshots "${COPY_FILTER_ARGS[@]}" >&2 || true
    bm_report_line "copy: [dry-run] previewed ${SRC_COUNT} snapshots, no data written"
    bm_success "[dry-run] Preview complete. No data was copied."
    bm_log_file "backend-migrate: dry-run OK (source=${SRC_REPO}, dest=${DEST_REPO}, snapshots=${SRC_COUNT})"
    exit 0
fi

# ── Step 3: copy snapshots ───────────────────────────────────────────────────

bm_step "Step 3: Copy snapshots (restic copy)"

# restic copy reads the source via RESTIC_REPOSITORY_FROM / *_FROM env vars and
# the source password via --from-password-file. The destination uses the
# parent-exported RESTIC_REPOSITORY / RESTIC_PASSWORD.
COPY_CMD=(restic copy --from-repo "$SRC_REPO" --from-password-file "$BM_FROM_PW_FILE")
if [ "${#COPY_FILTER_ARGS[@]}" -gt 0 ]; then
    COPY_CMD+=("${COPY_FILTER_ARGS[@]}")
fi

bm_info "Running: ${COPY_CMD[*]}"
bm_detail "(source and destination credentials are passed via env/temp-file, not shown)"

# Per-snapshot progress: if specific snapshots were given, copy them one by one
# so the user sees per-snapshot progress. Otherwise copy all matching at once.
COPY_OK=true
if [ "${#BM_SNAPSHOTS[@]}" -gt 0 ]; then
    i=0
    for s in "${BM_SNAPSHOTS[@]}"; do
        i=$((i+1))
        bm_detail "[$i/${#BM_SNAPSHOTS[@]}] copying snapshot ${s} ..."
        # Build per-snapshot command: base + tag/path/host filters + snapshot ID
        cmd=(restic copy --from-repo "$SRC_REPO" --from-password-file "$BM_FROM_PW_FILE")
        for t in "${BM_TAGS[@]:-}"; do   [ -n "$t" ] && cmd+=(--tag "$t"); done
        for p in "${BM_PATHS[@]:-}"; do  [ -n "$p" ] && cmd+=(--path "$p"); done
        for h in "${BM_HOSTS[@]:-}"; do  [ -n "$h" ] && cmd+=(--host "$h"); done
        cmd+=("$s")
        if ! "${cmd[@]}"; then
            bm_error "Failed to copy snapshot ${s}"
            bm_report_line "copy: FAILED snapshot=${s}"
            COPY_OK=false
        else
            bm_report_line "copy: OK snapshot=${s}"
        fi
    done
else
    if ! "${COPY_CMD[@]}"; then
        bm_error "restic copy failed."
        bm_report_line "copy: FAILED"
        COPY_OK=false
    else
        bm_report_line "copy: OK (all matching snapshots)"
    fi
fi

if ! $COPY_OK; then
    bm_error "One or more snapshots failed to copy. See report: $BM_REPORT"
    bm_log_file "backend-migrate: copy FAILED (source=${SRC_REPO}, dest=${DEST_REPO})"
    exit 1
fi

bm_success "Snapshots copied."
bm_log_file "backend-migrate: copy OK (source=${SRC_REPO}, dest=${DEST_REPO}, snapshots=${SRC_COUNT})"

# ── Step 4: verify destination ───────────────────────────────────────────────

bm_step "Step 4: Verify destination"

DEST_COUNT=0
if DEST_LIST_OUTPUT="$(restic snapshots --json 2>/dev/null)"; then
    DEST_COUNT="$(printf '%s\n' "$DEST_LIST_OUTPUT" | grep -c '"short_id"' || true)"
fi
bm_info "Destination snapshot count: ${DEST_COUNT}"
bm_report_line "dest-snapshots: ${DEST_COUNT}"

if $BM_VERIFY; then
    bm_info "Running restic check on destination ..."
    if restic check; then
        bm_success "Destination repository verified (restic check passed)."
        bm_report_line "verify: OK (restic check passed)"
    else
        bm_error "restic check failed on destination. Data may be incomplete."
        bm_report_line "verify: FAILED (restic check)"
        bm_log_file "backend-migrate: verify FAILED (dest=${DEST_REPO})"
        exit 1
    fi
else
    bm_warn "Skipping destination verification (--no-verify)."
    bm_report_line "verify: skipped (--no-verify)"
fi

# ── Done ─────────────────────────────────────────────────────────────────────

bm_step "Migration complete"
bm_success "Copied ${SRC_COUNT} snapshot(s) from source to destination."
bm_detail "Source      : ${SRC_REPO}"
bm_detail "Destination : ${DEST_REPO}"
bm_detail "Report      : ${BM_REPORT}"
bm_detail "Next: point your strategy env at the destination and run 'mb backup restore-test' to confirm."

bm_log_file "backend-migrate: OK (source=${SRC_REPO}, dest=${DEST_REPO}, snapshots=${SRC_COUNT}, verify=${BM_VERIFY})"
