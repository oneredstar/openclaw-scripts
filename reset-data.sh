#!/usr/bin/env bash

set -Eeuo pipefail
trap 'fail "Command failed at line $LINENO: $BASH_COMMAND"' ERR

export OPENCLAW_DATA_DIR="$HOME/openclaw-data"
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

backup_existing_data() {
    if [ -d "$OPENCLAW_DATA_DIR" ]; then
        ensure_dir "$OPENCLAW_BACKUP_ROOT"
        local backup_path="$OPENCLAW_BACKUP_ROOT/openclaw-data-$TIMESTAMP"
        log "Backing up existing OpenClaw data to $backup_path"
        cp -R "$OPENCLAW_DATA_DIR" "$backup_path"
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
    require_command cp
    backup_existing_data
    reset_data_dirs
    ensure_dir "$OPENCLAW_DATA_DIR"
    ensure_dir "$OPENCLAW_CONFIG_DIR"
    ensure_dir "$OPENCLAW_WORKSPACE_DIR"
    ensure_dir "$OPENCLAW_AUTH_PROFILE_SECRET_DIR"
}

main "$@"
