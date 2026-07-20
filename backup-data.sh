#!/usr/bin/env bash

set -Eeuo pipefail
trap 'fail "Command failed at line $LINENO: $BASH_COMMAND"' ERR

export OPENCLAW_DATA_DIR="$HOME/.openclaw-data"
export OPENCLAW_CONFIG_DIR="$OPENCLAW_DATA_DIR/config"
export OPENCLAW_WORKSPACE_DIR="$OPENCLAW_DATA_DIR/workspace"
export OPENCLAW_AUTH_PROFILE_SECRET_DIR="$OPENCLAW_DATA_DIR/auth-secrets"
export OPENCLAW_HOME_VOLUME="openclaw_home"

OPENCLAW_REPO_DIR="$HOME/openclaw"
OPENCLAW_REPO_URL="https://github.com/openclaw/openclaw.git"
OPENCLAW_BACKUP_ROOT="$HOME/openclaw-backups"
OPENCLAW_TEST_DATA_DIR="$HOME/openclaw-test-data"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

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

backup_data() {
    if [ ! -d "$OPENCLAW_DATA_DIR" ]; then
        log "No OpenClaw data found at $OPENCLAW_DATA_DIR; nothing to backup"
        return
    fi

    ensure_dir "$OPENCLAW_BACKUP_ROOT"

    local backup_path="$OPENCLAW_BACKUP_ROOT/openclaw-data-$TIMESTAMP"
    if [ -e "$backup_path" ]; then
        fail "Refusing to overwrite existing backup path: $backup_path"
    fi
    log "Backing up OpenClaw data to $backup_path"
    cp -a "$OPENCLAW_DATA_DIR" "$backup_path"
    verify_backup "$OPENCLAW_DATA_DIR" "$backup_path"

    log "Backup complete; original data directory $OPENCLAW_DATA_DIR left intact"
}

main() {
    require_command cp
    backup_data
}

main "$@"
