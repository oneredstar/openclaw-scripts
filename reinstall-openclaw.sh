#!/usr/bin/env bash

# reinstall-openclaw.sh — back up the existing OpenClaw install, tear down
# Docker resources scoped to openclaw, and clone a fresh stable release.
# Destructive: removes Docker images, networks, and the named openclaw_home
# volume belonging to this install. Source data is backed up first.

set -Eeuo pipefail
trap 'fail "Command failed at line $LINENO: $BASH_COMMAND"' ERR

export OPENCLAW_DATA_DIR="$HOME/.openclaw-data"
export OPENCLAW_CONFIG_DIR="$OPENCLAW_DATA_DIR/config"
export OPENCLAW_WORKSPACE_DIR="$OPENCLAW_DATA_DIR/workspace"
export OPENCLAW_AUTH_PROFILE_SECRET_DIR="$OPENCLAW_DATA_DIR/auth-secrets"
export OPENCLAW_HOME_VOLUME="openclaw_home"

OPENCLAW_REPO_DIR="$HOME/openclaw"
OPENCLAW_NODE_DIR="$HOME/.openclaw-mac-node"
OPENCLAW_REPO_URL="https://github.com/openclaw/openclaw.git"
OPENCLAW_BACKUP_ROOT="$HOME/openclaw-backups"
OPENCLAW_TEST_DATA_DIR="$HOME/openclaw-test-data"
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

Reinstalls OpenClaw by:
  1. Backing up \$OPENCLAW_DATA_DIR (and \$OPENCLAW_REPO_DIR if present) to
     \$OPENCLAW_BACKUP_ROOT with timestamped names and verifying them.
         If present, \$OPENCLAW_NODE_DIR is also backed up and verified.
  2. Stopping any running OpenClaw Docker compose stack (without --volumes;
     named volumes are removed explicitly below).
  3. Removing leftover OpenClaw containers, images, networks, and volumes.
    4. Removing the local clone, \$OPENCLAW_DATA_DIR, and \$OPENCLAW_NODE_DIR.
  5. Cloning the latest stable OpenClaw release and running the Docker setup.

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
        log "No existing OpenClaw installation found at $OPENCLAW_DATA_DIR; skipping data backup"
    fi
}

backup_existing_repo() {
    if [ -d "$OPENCLAW_REPO_DIR" ]; then
        ensure_dir "$OPENCLAW_BACKUP_ROOT"
        local backup_path="$OPENCLAW_BACKUP_ROOT/openclaw-repo-$TIMESTAMP"
        if [ -e "$backup_path" ]; then
            fail "Refusing to overwrite existing backup path: $backup_path"
        fi
        log "Backing up existing OpenClaw repo to $backup_path"
        cp -a "$OPENCLAW_REPO_DIR" "$backup_path"
        verify_backup "$OPENCLAW_REPO_DIR" "$backup_path"
    else
        log "No existing OpenClaw repo at $OPENCLAW_REPO_DIR; skipping repo backup"
    fi
}

backup_existing_node() {
    if [ -d "$OPENCLAW_NODE_DIR" ]; then
        ensure_dir "$OPENCLAW_BACKUP_ROOT"
        local backup_path="$OPENCLAW_BACKUP_ROOT/openclaw-node-$TIMESTAMP"
        if [ -e "$backup_path" ]; then
            fail "Refusing to overwrite existing backup path: $backup_path"
        fi
        log "Backing up existing OpenClaw node data to $backup_path"
        cp -a "$OPENCLAW_NODE_DIR" "$backup_path"
        verify_backup "$OPENCLAW_NODE_DIR" "$backup_path"
    else
        log "No existing OpenClaw node data at $OPENCLAW_NODE_DIR; skipping node backup"
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
            log "Stopping existing OpenClaw compose stack (volumes preserved; removed explicitly below)"
            # NOTE: do NOT pass --volumes here. Named volumes defined in the
            # compose file are removed by the explicit docker volume rm
            # step below, so a wide --volumes here would also nuke any
            # unrelated volumes the compose file references.
            docker compose down --remove-orphans || log "docker compose down reported an issue; continuing cleanup"
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

    # Narrow filter: only images whose first component is 'openclaw' or whose
    # repository path is '.../openclaw' (followed by '-', '/', ':', or end).
    # Avoids stomping third-party images that merely contain the substring
    # "openclaw" elsewhere in the name.
    openclaw_image_ids="$({
        docker images --format '{{.Repository}} {{.ID}}' \
            | awk '$1 ~ /^(.*\/)?openclaw($|[-\/:])/ { print $2 }'
        printf '%s\n' "$compose_image_ids"
    } | awk 'NF' | sort -u)"

    if [ -n "$openclaw_image_ids" ]; then
        log "Removing OpenClaw Docker images"
        # No -f: surface "image in use" or "multiple tags" errors instead of
        # silently forcing removal of unexpected references.
        printf '%s\n' "$openclaw_image_ids" | xargs docker rmi || log "One or more images could not be removed; continuing"
    else
        log "No OpenClaw Docker images found"
    fi

    openclaw_network_names="$(docker network ls --format '{{.Name}}' | awk '$0 ~ /^(.*\/)?openclaw($|[-_:])/' | sort -u)"
    if [ -n "$openclaw_network_names" ]; then
        log "Removing OpenClaw Docker networks"
        printf '%s\n' "$openclaw_network_names" | xargs docker network rm || log "One or more networks could not be removed; continuing"
    else
        log "No OpenClaw Docker networks found"
    fi

    openclaw_volume_names="$(docker volume ls --format '{{.Name}}' | awk '$0 ~ /^(.*\/)?openclaw($|[-_:])/' | sort -u)"
    if docker volume inspect "$OPENCLAW_HOME_VOLUME" >/dev/null 2>&1; then
        openclaw_volume_names="$({
            printf '%s\n' "$openclaw_volume_names"
            printf '%s\n' "$OPENCLAW_HOME_VOLUME"
        } | awk 'NF' | sort -u)"
    fi
    if [ -n "$openclaw_volume_names" ]; then
        log "Removing OpenClaw Docker volumes"
        # No -f: let 'volume in use' errors surface so we don't silently
        # delete a volume that's mounted by something unexpected.
        printf '%s\n' "$openclaw_volume_names" | xargs docker volume rm || log "One or more volumes could not be removed; continuing"
    else
        log "No OpenClaw Docker volumes found"
    fi

    if [ -d "$OPENCLAW_DATA_DIR" ]; then
        log "Removing $OPENCLAW_DATA_DIR"
        rm -rf "$OPENCLAW_DATA_DIR"
    fi

    if [ -d "$OPENCLAW_NODE_DIR" ]; then
        log "Removing $OPENCLAW_NODE_DIR"
        rm -rf "$OPENCLAW_NODE_DIR"
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
    log "Cloning OpenClaw repository"
    cd "$HOME"
    git clone "$OPENCLAW_REPO_URL" "$OPENCLAW_REPO_DIR"
    cd "$OPENCLAW_REPO_DIR"

    git fetch --tags --force
    local latest_tag
    latest_tag="$(git tag --list 'v*' --sort=-version:refname | grep -E '^v[0-9]+(\.[0-9]+)*$' | head -n 1)"

    if [ -z "$latest_tag" ]; then
        fail "Could not determine the latest stable OpenClaw tag"
    fi

    log "Checking out latest stable release $latest_tag"
    if git switch --detach "$latest_tag" >/dev/null 2>&1; then
        log "Checked out $latest_tag with git switch --detach"
    else
        git checkout --detach "$latest_tag"
        log "Checked out $latest_tag with git checkout --detach"
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

    require_command git
    require_command docker
    require_command cp
    unlock_login_keychain
    docker info >/dev/null 2>&1 || fail "Docker daemon is not reachable"

    log "Reinstall will:"
    log "  - back up data dir to   $OPENCLAW_BACKUP_ROOT/openclaw-data-$TIMESTAMP"
    if [ -d "$OPENCLAW_NODE_DIR" ]; then
        log "  - back up node dir to   $OPENCLAW_BACKUP_ROOT/openclaw-node-$TIMESTAMP"
    fi
    if [ -d "$OPENCLAW_REPO_DIR" ]; then
        log "  - back up repo to      $OPENCLAW_BACKUP_ROOT/openclaw-repo-$TIMESTAMP"
    fi
    log "  - stop the compose stack (named volumes kept until explicit removal)"
    log "  - remove leftover openclaw containers, images, networks, volumes"
    log "  - remove $OPENCLAW_REPO_DIR, $OPENCLAW_DATA_DIR, and $OPENCLAW_NODE_DIR"
    log "  - clone the latest stable release and run the Docker setup"
    confirm "Type 'reinstall' to continue: " "reinstall"

    backup_existing_data
    backup_existing_repo
    backup_existing_node
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

    log "Reinstall complete"
    log "Data backup:   $OPENCLAW_BACKUP_ROOT/openclaw-data-$TIMESTAMP"
    if [ -d "$OPENCLAW_BACKUP_ROOT/openclaw-repo-$TIMESTAMP" ]; then
        log "Repo backup:   $OPENCLAW_BACKUP_ROOT/openclaw-repo-$TIMESTAMP"
    fi
    if [ -d "$OPENCLAW_BACKUP_ROOT/openclaw-node-$TIMESTAMP" ]; then
        log "Node backup:   $OPENCLAW_BACKUP_ROOT/openclaw-node-$TIMESTAMP"
    fi
}

main "$@"
