#!/usr/bin/env bash
# lib/drill.sh — Recovery drill logic for mb (backup-kit)
# Sourced by mb. Do not execute directly.
#
# A recovery drill proves your backups are usable by:
#   1. Running a fresh backup
#   2. Restoring it to a temporary directory
#   3. Comparing file count and total size between source and restore
#   4. Generating a text report
#   5. Cleaning up the temporary directory

set -euo pipefail

# ── mb_drill_run ─────────────────────────────────────────────────────────────
# Execute a full recovery drill for the active strategy.
# Optional args: --strategy NAME, --source PATH, --target PATH
mb_drill_run() {
    local strategy="$(mb_get_active_strategy)"
    local source="${MB_DATA_DIR}"
    local target="${MB_RESTORE_DIR}/drill-$(date '+%Y%m%d-%H%M%S')"
    local report="${MB_STATE_DIR}/drill-report-$(date '+%Y%m%d-%H%M%S').txt"

    # Parse args
    while [ $# -gt 0 ]; do
        case "$1" in
            --strategy) strategy="$2"; shift 2 ;;
            --source)   source="$2"; shift 2 ;;
            --target)   target="$2"; shift 2 ;;
            *) mb_error "Unknown drill option: $1"; return 1 ;;
        esac
    done

    [ -z "$strategy" ] && { mb_error "No active strategy configured. Run 'mb backup init' first."; return 1; }
    mb_strategy_exists "$strategy" || { mb_error "Strategy not found: $strategy"; return 1; }
    [ -d "$source" ] || { mb_error "Source data directory does not exist: $source"; return 1; }

    mb_load_strategy_env "$strategy"
    mb_ensure_dir "$MB_STATE_DIR"

    mb_step "Starting recovery drill"
    mb_info "Strategy : $strategy"
    mb_info "Source   : $source"
    mb_info "Target   : $target"
    mb_info "Report   : $report"
    mb_log_file "drill: started (strategy=${strategy}, source=${source})"

    local start_ts end_ts elapsed
    start_ts=$(date +%s)

    # ── 1. Run a backup ──────────────────────────────────────────────────────
    mb_step "Step 1/5 — Running a fresh backup"
    local backup_script="$(mb_strategy_dir "$strategy")/backup.sh"
    if [ ! -x "$backup_script" ]; then
        mb_error "Backup script not executable: $backup_script"
        return 1
    fi
    if ! "$backup_script"; then
        mb_error "Backup step failed. Aborting drill."
        mb_log_file "drill: backup step FAILED"
        return 1
    fi
    mb_success "Backup completed."

    # ── 2. Restore to temp directory ─────────────────────────────────────────
    mb_step "Step 2/5 — Restoring latest snapshot to ${target}"
    local restore_script="$(mb_strategy_dir "$strategy")/restore.sh"
    if [ ! -x "$restore_script" ]; then
        mb_error "Restore script not executable: $restore_script"
        return 1
    fi
    mb_ensure_dir "$target"
    if ! "$restore_script" --latest --target "$target"; then
        mb_error "Restore step failed. Aborting drill."
        mb_log_file "drill: restore step FAILED"
        mb_cleanup_dir "$target"
        return 1
    fi
    mb_success "Restore completed."

    # ── 3. Compare file count and total size ─────────────────────────────────
    mb_step "Step 3/5 — Comparing source and restored data"

    local src_files src_bytes dst_files dst_bytes
    src_files=$(mb_count_files "$source")
    src_bytes=$(mb_dir_size_bytes "$source")
    dst_files=$(mb_count_files "$target")
    dst_bytes=$(mb_dir_size_bytes "$target")

    mb_detail "Source   : ${src_files} files, $(mb_human_size "$src_bytes")"
    mb_detail "Restored : ${dst_files} files, $(mb_human_size "$dst_bytes")"

    local verdict="PASS" reason=""
    if [ "$src_files" -ne "$dst_files" ]; then
        verdict="FAIL"
        reason="file count mismatch (source=${src_files}, restored=${dst_files})"
    fi
    # Allow small size delta due to filesystem metadata rounding, but flag >5%
    local size_delta=0
    if [ "$src_bytes" -gt 0 ]; then
        size_delta=$(( (dst_bytes - src_bytes) * 100 / src_bytes ))
        if [ "$size_delta" -lt 0 ]; then size_delta=$((-size_delta)); fi
    fi
    if [ "$size_delta" -gt 5 ]; then
        verdict="FAIL"
        reason="${reason:+${reason}; }size delta ${size_delta}% exceeds 5% threshold"
    fi

    end_ts=$(date +%s)
    elapsed=$((end_ts - start_ts))

    # ── 4. Generate report ───────────────────────────────────────────────────
    mb_step "Step 4/5 — Generating report"
    {
        echo "=========================================="
        echo " mb-backup Recovery Drill Report"
        echo "=========================================="
        echo "Date       : $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Strategy   : ${strategy}"
        echo "Source     : ${source}"
        echo "Target     : ${target}"
        echo "Duration   : ${elapsed}s"
        echo ""
        echo "---- Metrics ----"
        echo "Source files     : ${src_files}"
        echo "Source size      : $(mb_human_size "$src_bytes") (${src_bytes} bytes)"
        echo "Restored files   : ${dst_files}"
        echo "Restored size    : $(mb_human_size "$dst_bytes") (${dst_bytes} bytes)"
        echo "Size delta       : ${size_delta}%"
        echo ""
        echo "---- Verdict ----"
        echo "Result           : ${verdict}"
        if [ -n "$reason" ]; then
            echo "Reason           : ${reason}"
        fi
        echo ""
        echo "A backup you have never tested is just a hope, not a backup."
        echo "=========================================="
    } > "$report"
    mb_detail "Report written to ${report}"

    if [ "$verdict" = "PASS" ]; then
        mb_success "Drill PASSED — backups are recoverable."
        mb_log_file "drill: PASS (files=${src_files}, size_delta=${size_delta}%)"
        mb_mark_drill
    else
        mb_error "Drill FAILED — ${reason}"
        mb_log_file "drill: FAIL (${reason})"
    fi

    # ── 5. Clean up ──────────────────────────────────────────────────────────
    mb_step "Step 5/5 — Cleaning up temporary directory"
    mb_cleanup_dir "$target"
    mb_detail "Removed ${target}"
    mb_info "Drill report kept at: ${report}"

    [ "$verdict" = "PASS" ]
}
