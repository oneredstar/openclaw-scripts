#!/usr/bin/env bash

# reset-data.sh — back up, then remove, the OpenClaw data directory and
# re-create an empty config/workspace/auth-secrets structure. Destructive.

set -Eeuo pipefail
trap 'fail "Command failed at line $LINENO: $BASH_COMMAND"' ERR

export OPENCLAW_DATA_DIR="$HOME/openclaw-data"
export OPENCLAW_CONFIG_DIR="$OPENCLAW_DATA_DIR/config"
export OPENCLAW_WORKSPACE_DIR="$OPENCLAW_DATA_DIR/workspace"
export OPENCLAW_AUTH_PROFILE_SECRET_DIR="$OPENCLAW_DATA_DIR/auth-secrets"

OPENCLAW_BACKUP_ROOT="$HOME/openclaw-backups"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

YES=0

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

fail() {
    log "ERROR: $*"
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

ensure_dir() {
    if [ ! -d "$1" ]; then
        log "Creating directory $1"
        mkdir -p "$1"
    fi
}

usage() {
    cat <<USAGE
Usage: $(basename "$0") [--yes]

Removes \$OPENCLAW_DATA_DIR (default: ~/openclaw-data) and re-creates the
standard config/workspace/auth-secrets structure. A timestamped backup is
written under \$OPENCLAW_BACKUP_ROOT first and verified before the source
is removed.

Options:
  -y, --yes    Skip the interactive confirmation prompt
  -h, --help   Show this help and exit
USAGE
}

entry_count() {
    find "$1" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ' | sed 's/^0$/0/'
}

verify_backup() {
    local src="$1"
    local backup="$2"

    [ -d "$backup" ] || fail "Backup verification failed: $backup was not created"

    local src_count backup_count
    src_count="$(entry_count "$src")"
    backup_count="$(entry_count "$backup")"

    if [ "$src_count" -ne "$backup_count" ]; then
        fail "Backup verification failed: $src has $src_count top-level entries but $backup has $backup_count"
    fi

    log "Backup verified: $backup_count top-level entries match $src"
}

confirm() {
    local prompt="$1"
    local expected="${2:-yes}"
    if [ "$YES" = "1" ]; then
        log "Confirmation skipped (--yes): $prompt"
        return 0
    fi
    if [ ! -t 0 ]; then
        fail "Refusing to proceed without an interactive terminal. Re-run with --yes to skip the confirmation prompt."
    fi
    printf '%s' "$prompt"
    local response
    read -r response
    if [ "$response" != "$expected" ]; then
        log "Aborted by user (expected '$expected', got '$response')"
        exit 1
    fi
}

backup_existing_data() {
    if [ -d "$OPENCLAW_DATA_DIR" ]; then
        ensure_dir "$OPENCLAW_BACKUP_ROOT"
        local backup_path="$OPENCLAW_BACKUP_ROOT/openclaw-data-$TIMESTAMP"
        if [ -e "$backup_path" ]; then
            fail "Refusing to overwrite existing backup path: $backup_path"
        fi
        log "Backing up existing OpenClaw data to $backup_path"
        cp -a "$OPENCLAW_DATA_DIR" "$backup_path"
        verify_backup "$OPENCLAW_DATA_DIR" "$backup_path"
    else
        log "No existing OpenClaw installation found at $OPENCLAW_DATA_DIR; skipping backup"
    fi
}

reset_data_dirs() {
    if [ -d "$OPENCLAW_DATA_DIR" ]; then
        log "Removing existing OpenClaw data directory $OPENCLAW_DATA_DIR"
        rm -rf "$OPENCLAW_DATA_DIR"
    fi
}

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -y|--yes)
                YES=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                fail "Unknown argument: $1 (use --help for usage)"
                ;;
        esac
    done

    require_command cp

    if [ -d "$OPENCLAW_DATA_DIR" ]; then
        log "About to reset OpenClaw data at $OPENCLAW_DATA_DIR"
        log "A timestamped backup will be written to $OPENCLAW_BACKUP_ROOT before anything is removed."
        confirm "Type 'reset' to continue: " "reset"
    fi

    backup_existing_data
    reset_data_dirs
    ensure_dir "$OPENCLAW_DATA_DIR"
    ensure_dir "$OPENCLAW_CONFIG_DIR"
    ensure_dir "$OPENCLAW_WORKSPACE_DIR"
    ensure_dir "$OPENCLAW_AUTH_PROFILE_SECRET_DIR"

    log "Reset complete; data directory reinitialized at $OPENCLAW_DATA_DIR"
}

main "$@"
