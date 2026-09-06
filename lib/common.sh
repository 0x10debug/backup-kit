#!/usr/bin/env bash
# lib/common.sh — Common functions for mb (backup-kit)
# Sourced by mb and all subcommands. Do not execute directly.

set -euo pipefail

# ── Constants ────────────────────────────────────────────────────────────────

# shellcheck disable=SC2034 # printed by the mb entrypoint after sourcing
MB_BACKUP_VERSION="1.0.0"

# Repository layout (resolved by mb, but provide sane defaults)
MB_BACKUP_DIR="${MB_BACKUP_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
MB_STRATEGIES_DIR="${MB_STRATEGIES_DIR:-${MB_BACKUP_DIR}/strategies}"
MB_DOCKER_DIR="${MB_DOCKER_DIR:-${MB_BACKUP_DIR}/docker}"
MB_CRON_DIR="${MB_CRON_DIR:-${MB_BACKUP_DIR}/cron}"

# Deployment / runtime paths
MB_DEPLOY_DIR="${MB_DEPLOY_DIR:-/opt/mb-backup}"
MB_CONFIG_DIR="${MB_CONFIG_DIR:-/etc/mb-backup}"
MB_ENV_FILE="${MB_ENV_FILE:-${MB_CONFIG_DIR}/env.sh}"
MB_STATE_DIR="${MB_STATE_DIR:-/var/lib/mb-backup}"
MB_LOG_FILE="${MB_LOG_FILE:-/var/log/mb-backup.log}"

# Default data and temporary backup locations
MB_DATA_DIR="${MB_DATA_DIR:-/data}"
MB_BACKUP_TMP="${MB_BACKUP_TMP:-/backup}"
MB_RESTORE_DIR="${MB_RESTORE_DIR:-/tmp/mb-restore}"

# Pick a writable log file: prefer /var/log when root, else a user location.
if [ -w "/var/log" ] 2>/dev/null; then
    MB_LOG_FILE="${MB_LOG_FILE:-/var/log/mb-backup.log}"
else
    MB_LOG_FILE="${MB_LOG_FILE:-${HOME}/.mb-backup.log}"
fi

# ── Colors ───────────────────────────────────────────────────────────────────

if [ -t 1 ]; then
    MB_RED='\033[0;31m'
    MB_GREEN='\033[0;32m'
    MB_YELLOW='\033[0;33m'
    MB_BLUE='\033[0;34m'
    MB_BOLD='\033[1m'
    MB_DIM='\033[2m'
    MB_RESET='\033[0m'
else
    MB_RED='' MB_GREEN='' MB_YELLOW='' MB_BLUE='' MB_BOLD='' MB_DIM='' MB_RESET=''
fi

# ── Logging ──────────────────────────────────────────────────────────────────

mb_log() {
    local level="$1"; shift
    local msg="$*"
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${MB_DIM}[${ts}]${MB_RESET} ${level} ${msg}"
}

mb_info()    { mb_log "${MB_BLUE}INFO${MB_RESET}"    "$*"; }
mb_success() { mb_log "${MB_GREEN}OK${MB_RESET}"     "$*"; }
mb_warn()    { mb_log "${MB_YELLOW}WARN${MB_RESET}"  "$*"; }
mb_error()   { mb_log "${MB_RED}ERROR${MB_RESET}"    "$*" >&2; }
mb_step()    { echo -e "\n${MB_BOLD}${MB_BLUE}==>${MB_RESET} ${MB_BOLD}$*${MB_RESET}"; }
mb_detail()  { echo -e "  ${MB_DIM}$*${MB_RESET}"; }

# Append a line to the log file (best-effort, never fatal)
mb_log_file() {
    local msg="$*"
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    ( mkdir -p "$(dirname "$MB_LOG_FILE")" 2>/dev/null
      echo "[${ts}] ${msg}" >> "$MB_LOG_FILE" ) 2>/dev/null || true
}

# ── Error handling ───────────────────────────────────────────────────────────

mb_die() {
    mb_error "$*"
    mb_log_file "FATAL: $*"
    exit 1
}

mb_run() {
    # Run a command quietly; return its exit code without exiting.
    if ! "$@" >/dev/null 2>&1; then
        return 1
    fi
    return 0
}

# ── Prerequisite checks ──────────────────────────────────────────────────────

mb_check_command() {
    # Returns 0 if the given command exists, 1 otherwise.
    command -v "$1" >/dev/null 2>&1
}

mb_check_restic() {
    if ! mb_check_command restic; then
        mb_error "restic is not installed."
        mb_detail "Install it:  https://restic.readthedocs.io/en/stable/020_installation.html"
        mb_detail "Or on Debian/Ubuntu:  apt-get install restic"
        return 1
    fi
    return 0
}

mb_check_kopia() {
    if ! mb_check_command kopia; then
        mb_error "kopia is not installed."
        mb_detail "Install it:  https://kopia.io/docs/installation/"
        return 1
    fi
    return 0
}

mb_check_borgmatic() {
    if ! mb_check_command borgmatic; then
        mb_error "borgmatic is not installed."
        mb_detail "Install it:  pip install borgmatic  (or apt-get install borgmatic)"
        return 1
    fi
    return 0
}

mb_check_docker() {
    if ! mb_check_command docker; then
        mb_error "docker is not installed."
        mb_detail "Install Docker first:  https://github.com/0x10debug/vps-bootstrap"
        return 1
    fi
    return 0
}

mb_check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        mb_warn "Not running as root — some paths (/data, /backup, /var/log) may be inaccessible."
    fi
}

# ── Interaction helpers ──────────────────────────────────────────────────────

mb_ask() {
    # Ask a yes/no question. Returns 0 for yes, 1 for no.
    local prompt="$1" default="${2:-y}"
    local reply
    if [ "$default" = "y" ]; then
        read -rp "$(echo -e "${MB_BOLD}${prompt}${MB_RESET} [Y/n] ")" reply
        reply="${reply:-y}"
    else
        read -rp "$(echo -e "${MB_BOLD}${prompt}${MB_RESET} [y/N] ")" reply
        reply="${reply:-n}"
    fi
    case "$reply" in
        [Yy]*) return 0 ;;
        [Nn]*) return 1 ;;
        *) return 1 ;;
    esac
}

mb_ask_value() {
    # Ask for a value with a default. Echoes the result.
    local prompt="$1" default="${2:-}"
    local reply
    if [ -n "$default" ]; then
        read -rp "$(echo -e "${MB_BOLD}${prompt}${MB_RESET} [${default}]: ")" reply
        echo "${reply:-$default}"
    else
        read -rp "$(echo -e "${MB_BOLD}${prompt}${MB_RESET}: ")" reply
        echo "$reply"
    fi
}

mb_ask_secret() {
    # Ask for a secret value (no echo). Echoes the result.
    local prompt="$1"
    local reply
    read -rsp "$(echo -e "${MB_BOLD}${prompt}${MB_RESET}: ")" reply
    echo "" >&2
    echo "$reply"
}

mb_ask_choice() {
    # Present numbered choices and echo the selected value.
    # Usage: mb_ask_choice "Prompt" "opt1" "opt2" "opt3"
    local prompt="$1"; shift
    local choices=("$@")
    local i=1
    echo -e "${MB_BOLD}${prompt}${MB_RESET}"
    for c in "${choices[@]}"; do
        echo -e "  ${MB_DIM}${i})${MB_RESET} ${c}"
        i=$((i + 1))
    done
    local reply
    read -rp "$(echo -e "${MB_BOLD}Select [1-${#choices[@]}]${MB_RESET}: ")" reply
    if [[ "$reply" =~ ^[0-9]+$ ]] && [ "$reply" -ge 1 ] && [ "$reply" -le "${#choices[@]}" ]; then
        echo "${choices[$((reply - 1))]}"
    else
        echo ""
        return 1
    fi
}

# ── Environment / config helpers ─────────────────────────────────────────────

mb_env_set() {
    # Set a key-value pair in the environment file.
    local key="$1" value="$2"
    mkdir -p "$MB_CONFIG_DIR"
    touch "$MB_ENV_FILE"
    sed -i "/^${key}=/d" "$MB_ENV_FILE" 2>/dev/null || true
    echo "${key}=\"${value}\"" >> "$MB_ENV_FILE"
}

mb_env_get() {
    # Get a value from the environment file.
    local key="$1"
    if [ -f "$MB_ENV_FILE" ]; then
        grep "^${key}=" "$MB_ENV_FILE" | head -1 | cut -d'=' -f2- | tr -d '"'
    fi
}

mb_env_source() {
    # Source the environment file if it exists.
    if [ -f "$MB_ENV_FILE" ]; then
        # shellcheck disable=SC1090
        source "$MB_ENV_FILE"
    fi
}

# ── Strategy helpers ─────────────────────────────────────────────────────────

# shellcheck disable=SC2034 # consumed by the mb entrypoint strategy picker
MB_AVAILABLE_STRATEGIES=(restic-s3 restic-sftp kopia-s3 borgmatic)

mb_strategy_dir() {
    # Echo the directory for a given strategy name.
    local strategy="$1"
    echo "${MB_STRATEGIES_DIR}/${strategy}"
}

mb_strategy_exists() {
    local strategy="$1"
    [ -d "$(mb_strategy_dir "$strategy")" ]
}

mb_get_active_strategy() {
    # Echo the currently configured strategy, or empty.
    mb_env_get MB_STRATEGY
}

mb_set_active_strategy() {
    local strategy="$1"
    mb_env_set MB_STRATEGY "$strategy"
}

mb_load_strategy_env() {
    # Source the strategy .env file (if present) into the current shell.
    local strategy="$1"
    local envfile
    envfile="$(mb_strategy_dir "$strategy")/.env"
    if [ -f "$envfile" ]; then
        # shellcheck disable=SC1090
        source "$envfile"
    fi
}

# ── State helpers ────────────────────────────────────────────────────────────

mb_mark_backup() {
    # Record a backup run timestamp.
    mkdir -p "$MB_STATE_DIR"
    date '+%Y-%m-%d %H:%M:%S' > "${MB_STATE_DIR}/last-backup"
}

mb_last_backup_time() {
    if [ -f "${MB_STATE_DIR}/last-backup" ]; then
        cat "${MB_STATE_DIR}/last-backup"
    else
        echo "never"
    fi
}

mb_mark_drill() {
    mkdir -p "$MB_STATE_DIR"
    date '+%Y-%m-%d %H:%M:%S' > "${MB_STATE_DIR}/last-drill"
}

mb_last_drill_time() {
    if [ -f "${MB_STATE_DIR}/last-drill" ]; then
        cat "${MB_STATE_DIR}/last-drill"
    else
        echo "never"
    fi
}

# ── Misc utilities ───────────────────────────────────────────────────────────

mb_human_size() {
    # Convert a byte count to a human-readable string.
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

mb_count_files() {
    # Count regular files under a path (recursive).
    local path="$1"
    if [ -d "$path" ]; then
        find "$path" -type f 2>/dev/null | wc -l | tr -d ' '
    else
        echo 0
    fi
}

mb_dir_size_bytes() {
    # Total size in bytes of a path. Uses `du -k` (portable across GNU/BSD)
    # and converts kilobytes to bytes for a consistent comparison metric.
    local path="$1"
    if [ -d "$path" ]; then
        du -sk "$path" 2>/dev/null | awk '{print $1 * 1024}'
    else
        echo 0
    fi
}

mb_ensure_dir() {
    mkdir -p "$1"
}

mb_cleanup_dir() {
    # Safely remove a directory if it exists.
    local dir="$1"
    if [ -n "$dir" ] && [ -d "$dir" ]; then
        rm -rf -- "$dir"
    fi
}
