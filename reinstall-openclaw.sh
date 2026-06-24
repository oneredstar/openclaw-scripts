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

unlock_login_keychain() {
    local login_keychain="$HOME/Library/Keychains/login.keychain-db"

    require_command security

    if [ ! -f "$login_keychain" ]; then
        fail "Expected login keychain at $login_keychain, but it was not found"
    fi

    log "Unlocking the macOS login keychain. Enter your password if prompted."

    if [ -t 0 ] && [ -t 1 ]; then
        security -v unlock-keychain "$login_keychain"
    elif [ -r /dev/tty ] && [ -w /dev/tty ]; then
        security -v unlock-keychain "$login_keychain" </dev/tty >/dev/tty
    else
        fail "No interactive terminal is available to unlock the login keychain"
    fi
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

cleanup_existing_installation() {
    local compose_image_ids=""
    local openclaw_image_ids=""
    local openclaw_container_ids=""
    local openclaw_network_names=""
    local openclaw_volume_names=""
    local original_dir="$PWD"

    if [ -d "$OPENCLAW_REPO_DIR" ]; then
        cd "$OPENCLAW_REPO_DIR"

        if docker compose config >/dev/null 2>&1; then
            log "Stopping existing OpenClaw compose stack"
            docker compose down --volumes --remove-orphans || log "docker compose down reported an issue; continuing cleanup"
            compose_image_ids="$(docker compose images -q 2>/dev/null | awk 'NF' | sort -u)"
        else
            log "Existing repo does not have a usable docker compose configuration; skipping compose-managed cleanup"
        fi
    else
        log "No existing repo found at $OPENCLAW_REPO_DIR; skipping compose-managed cleanup"
    fi

    openclaw_container_ids="$(docker ps -a --filter name=openclaw --format '{{.ID}}' | awk 'NF' | sort -u)"
    if [ -n "$openclaw_container_ids" ]; then
        log "Removing leftover OpenClaw containers"
        printf '%s\n' "$openclaw_container_ids" | xargs docker rm -f
    else
        log "No leftover OpenClaw containers found"
    fi

    openclaw_image_ids="$({
        docker images --format '{{.Repository}} {{.ID}}' | awk '/openclaw/ {print $2}'
        printf '%s\n' "$compose_image_ids"
    } | awk 'NF' | sort -u)"
    if [ -n "$openclaw_image_ids" ]; then
        log "Removing OpenClaw Docker images"
        printf '%s\n' "$openclaw_image_ids" | xargs docker rmi -f || log "One or more images were already removed; continuing"
    else
        log "No OpenClaw Docker images found"
    fi

    openclaw_network_names="$(docker network ls --format '{{.Name}}' | awk '/openclaw/ {print $0}' | sort -u)"
    if [ -n "$openclaw_network_names" ]; then
        log "Removing OpenClaw Docker networks"
        printf '%s\n' "$openclaw_network_names" | xargs docker network rm || log "One or more networks were already removed; continuing"
    else
        log "No OpenClaw Docker networks found"
    fi

    openclaw_volume_names="$(docker volume ls --format '{{.Name}}' | awk '/openclaw/ {print $0}' | sort -u)"
    if docker volume inspect "$OPENCLAW_HOME_VOLUME" >/dev/null 2>&1; then
        openclaw_volume_names="$({
            printf '%s\n' "$openclaw_volume_names"
            printf '%s\n' "$OPENCLAW_HOME_VOLUME"
        } | awk 'NF' | sort -u)"
    fi
    if [ -n "$openclaw_volume_names" ]; then
        log "Removing OpenClaw Docker volumes"
        printf '%s\n' "$openclaw_volume_names" | xargs docker volume rm -f || log "One or more volumes were already removed; continuing"
    else
        log "No OpenClaw Docker volumes found"
    fi

    if [ -d "$HOME/.openclaw" ]; then
        log "Removing $HOME/.openclaw"
        rm -rf "$HOME/.openclaw"
    fi

    if [ -d "$OPENCLAW_REPO_DIR" ]; then
        log "Removing $OPENCLAW_REPO_DIR"
        cd "$HOME"
        rm -rf "$OPENCLAW_REPO_DIR"
    fi

    if [ -d "$original_dir" ]; then
        cd "$original_dir"
    else
        cd "$HOME"
    fi
}

clone_latest_stable_release() {
    local latest_tag

    log "Cloning OpenClaw repository"
    cd "$HOME"
    git clone "$OPENCLAW_REPO_URL" "$OPENCLAW_REPO_DIR"
    cd "$OPENCLAW_REPO_DIR"

    git fetch --tags --force
    latest_tag="$(git tag --list 'v*' --sort=-version:refname | grep -E '^v[0-9]+(\.[0-9]+)*$' | head -n 1)"

    if [ -z "$latest_tag" ]; then
        fail "Could not determine the latest stable OpenClaw tag"
    fi

    log "Checking out latest stable release $latest_tag"
    git switch --detach "$latest_tag"
}

main() {
    require_command git
    require_command docker
    require_command cp
    unlock_login_keychain
    docker info >/dev/null 2>&1 || fail "Docker daemon is not reachable"

    backup_existing_data
    cleanup_existing_installation
    clone_latest_stable_release

    ensure_dir "$OPENCLAW_CONFIG_DIR"
    ensure_dir "$OPENCLAW_WORKSPACE_DIR"
    ensure_dir "$OPENCLAW_AUTH_PROFILE_SECRET_DIR"
    ensure_dir "$OPENCLAW_BACKUP_ROOT"
    ensure_dir "$OPENCLAW_TEST_DATA_DIR"

    cd "$OPENCLAW_REPO_DIR"
    log "Running Docker setup"
    ./scripts/docker/setup.sh
}

main "$@"
