#!/usr/bin/env bash
# lib/verify.sh — Backup integrity verification for mb (backup-kit)
# Sourced by mb. Do not execute directly.

set -euo pipefail

# ── mb_verify_backup ─────────────────────────────────────────────────────────
# Run the native repository integrity check for the active strategy.
# Returns 0 on success, non-zero on failure.
mb_verify_backup() {
    local strategy="${1:-$(mb_get_active_strategy)}"
    [ -z "$strategy" ] && { mb_error "No active strategy configured. Run 'mb backup init' first."; return 1; }

    mb_load_strategy_env "$strategy"
    mb_step "Verifying backup integrity (strategy: ${strategy})"

    case "$strategy" in
        restic-s3|restic-sftp)
            mb_check_restic || return 1
            if [ -z "${RESTIC_REPOSITORY:-}" ]; then
                mb_error "RESTIC_REPOSITORY is not set."
                return 1
            fi
            mb_info "Running restic check on ${RESTIC_REPOSITORY} ..."
            mb_log_file "verify: restic check started (${RESTIC_REPOSITORY})"
            if restic check; then
                mb_success "Restic repository integrity verified."
                mb_log_file "verify: restic check OK"
                return 0
            else
                mb_error "Restic check failed. Repository may be corrupt."
                mb_log_file "verify: restic check FAILED"
                return 1
            fi
            ;;
        kopia-s3)
            mb_check_kopia || return 1
            mb_info "Running kopia snapshot verify ..."
            mb_log_file "verify: kopia snapshot verify started"
            if kopia snapshot verify; then
                mb_success "Kopia snapshots verified."
                mb_log_file "verify: kopia snapshot verify OK"
                return 0
            else
                mb_error "Kopia verification failed."
                mb_log_file "verify: kopia snapshot verify FAILED"
                return 1
            fi
            ;;
        borgmatic)
            mb_check_borgmatic || return 1
            mb_info "Running borgmatic --verbosity 1 check ..."
            mb_log_file "verify: borgmatic check started"
            if borgmatic --verbosity 1; then
                mb_success "Borgmatic repository verified."
                mb_log_file "verify: borgmatic check OK"
                return 0
            else
                mb_error "Borgmatic check failed."
                mb_log_file "verify: borgmatic check FAILED"
                return 1
            fi
            ;;
        *)
            mb_error "Unknown strategy: $strategy"
            return 1
            ;;
    esac
}

# ── mb_verify_integrity ──────────────────────────────────────────────────────
# Deep integrity check: run the native check AND verify the most recent
# snapshot can be listed and its stats read. Returns 0 on success.
mb_verify_integrity() {
    local strategy="${1:-$(mb_get_active_strategy)}"
    [ -z "$strategy" ] && { mb_error "No active strategy configured."; return 1; }

    mb_load_strategy_env "$strategy"

    # First: native repository check
    mb_verify_backup "$strategy" || return 1

    mb_step "Verifying latest snapshot is readable"
    case "$strategy" in
        restic-s3|restic-sftp)
            if restic snapshots --latest 1 >/dev/null 2>&1 && restic stats latest >/dev/null 2>&1; then
                mb_success "Latest snapshot is readable and stats available."
                return 0
            else
                mb_error "Could not read latest snapshot stats."
                return 1
            fi
            ;;
        kopia-s3)
            if kopia snapshot list --all >/dev/null 2>&1; then
                mb_success "Kopia snapshot list readable."
                return 0
            else
                mb_error "Could not list Kopia snapshots."
                return 1
            fi
            ;;
        borgmatic)
            if borgmatic list >/dev/null 2>&1; then
                mb_success "Borgmatic archive list readable."
                return 0
            else
                mb_error "Could not list borgmatic archives."
                return 1
            fi
            ;;
    esac
}
