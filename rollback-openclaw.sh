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

latest_repo_backup() {
    local latest_path

    latest_path="$(find "$OPENCLAW_BACKUP_ROOT" -maxdepth 1 -type d -name 'openclaw-repo-*' -print | sort | tail -n 1)"
    [ -n "$latest_path" ] || fail "No repo backups were found in $OPENCLAW_BACKUP_ROOT"
    printf '%s\n' "${latest_path##*/openclaw-repo-}"
}

resolve_backup_id() {
    if [ $# -ge 1 ] && [ -n "${1:-}" ]; then
        printf '%s\n' "$1"
        return
    fi

    latest_repo_backup
}

backup_current_state() {
    ensure_dir "$OPENCLAW_BACKUP_ROOT"

    if [ -d "$OPENCLAW_REPO_DIR" ]; then
        local repo_backup_path="$OPENCLAW_BACKUP_ROOT/pre-rollback-repo-$TIMESTAMP"
        log "Backing up current repo to $repo_backup_path"
        cp -R "$OPENCLAW_REPO_DIR" "$repo_backup_path"
    else
        log "No current repo found at $OPENCLAW_REPO_DIR; skipping current repo backup"
    fi

    if [ -d "$OPENCLAW_DATA_DIR" ]; then
        local data_backup_path="$OPENCLAW_BACKUP_ROOT/pre-rollback-data-$TIMESTAMP"
        log "Backing up current data to $data_backup_path"
        cp -R "$OPENCLAW_DATA_DIR" "$data_backup_path"
    else
        log "No current data directory found at $OPENCLAW_DATA_DIR; skipping current data backup"
    fi
}

stop_current_stack() {
    if [ ! -d "$OPENCLAW_REPO_DIR" ]; then
        log "No current repo found at $OPENCLAW_REPO_DIR; skipping docker compose down"
        return
    fi

    cd "$OPENCLAW_REPO_DIR"

    if docker compose config >/dev/null 2>&1; then
        log "Stopping current OpenClaw Docker compose stack"
        docker compose down --remove-orphans
    else
        log "No usable docker compose configuration found in $OPENCLAW_REPO_DIR; skipping docker compose down"
    fi
}

restore_repo_backup() {
    local backup_id="$1"
    local repo_backup_path="$OPENCLAW_BACKUP_ROOT/openclaw-repo-$backup_id"

    [ -d "$repo_backup_path" ] || fail "Repo backup not found: $repo_backup_path"

    if [ -d "$OPENCLAW_REPO_DIR" ]; then
        log "Removing current repo at $OPENCLAW_REPO_DIR"
        rm -rf "$OPENCLAW_REPO_DIR"
    fi

    log "Restoring repo backup from $repo_backup_path"
    cp -R "$repo_backup_path" "$OPENCLAW_REPO_DIR"
}

restore_data_backup() {
    local backup_id="$1"
    local data_backup_path="$OPENCLAW_BACKUP_ROOT/openclaw-data-$backup_id"

    if [ ! -d "$data_backup_path" ]; then
        log "No matching data backup found at $data_backup_path; leaving current data directory unchanged"
        return
    fi

    if [ -d "$OPENCLAW_DATA_DIR" ]; then
        log "Removing current data directory at $OPENCLAW_DATA_DIR"
        rm -rf "$OPENCLAW_DATA_DIR"
    fi

    log "Restoring data backup from $data_backup_path"
    cp -R "$data_backup_path" "$OPENCLAW_DATA_DIR"
}

start_restored_stack() {
    cd "$OPENCLAW_REPO_DIR"

    if docker compose config >/dev/null 2>&1; then
        log "Starting restored OpenClaw Docker compose stack"
        docker compose up -d
    else
        fail "Could not find a usable docker compose configuration in restored repo $OPENCLAW_REPO_DIR"
    fi
}

print_summary() {
    local backup_id="$1"

    log "Rollback complete"
    log "Restored repo backup: $OPENCLAW_BACKUP_ROOT/openclaw-repo-$backup_id"

    if [ -d "$OPENCLAW_BACKUP_ROOT/openclaw-data-$backup_id" ]; then
        log "Restored data backup: $OPENCLAW_BACKUP_ROOT/openclaw-data-$backup_id"
    fi

    log "Pre-rollback repo backup: $OPENCLAW_BACKUP_ROOT/pre-rollback-repo-$TIMESTAMP"
    log "Pre-rollback data backup: $OPENCLAW_BACKUP_ROOT/pre-rollback-data-$TIMESTAMP"
}

main() {
    local backup_id

    require_command docker
    require_command cp
    require_command find
    docker info >/dev/null 2>&1 || fail "Docker daemon is not reachable"

    backup_id="$(resolve_backup_id "${1:-}")"

    backup_current_state
    stop_current_stack
    restore_repo_backup "$backup_id"
    restore_data_backup "$backup_id"
    start_restored_stack
    print_summary "$backup_id"
}

main "$@"
