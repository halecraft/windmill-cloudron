#!/usr/bin/env bash
# deploy.sh — Build, deploy, and clean up windmill-cloudron in one command.
#
# Usage:
#   ./deploy.sh              # Build and update existing install
#   ./deploy.sh --reinstall  # Build, uninstall, and fresh install (destroys data)
#   ./deploy.sh --no-build   # Deploy last built image (skip Docker build)
#   ./deploy.sh --verbose    # Show raw Docker build output
#
# Configuration: .env file (see .env.example)
#
# Context: jj:tprorwko
set -euo pipefail

# ── Helpers ─────────────────────────────────────────────────────────

log()     { printf '[deploy] %s\n' "$*" >&2; }
die()     { printf '[deploy] ERROR: %s\n' "$*" >&2; exit 1; }
warn()    { printf '[deploy] WARN: %s\n' "$*" >&2; }

confirm() {
    local prompt="$1"
    printf '[deploy] %s [y/N] ' "$prompt" >&2
    read -r answer
    case "$answer" in
        [yY]|[yY][eE][sS]) return 0 ;;
        *) log "Aborted."; exit 0 ;;
    esac
}

# ── CLI flags ───────────────────────────────────────────────────────

FLAG_REINSTALL=false
FLAG_NO_BUILD=false
FLAG_VERBOSE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --reinstall)  FLAG_REINSTALL=true; shift ;;
        --no-build)   FLAG_NO_BUILD=true; shift ;;
        --verbose)    FLAG_VERBOSE=true; shift ;;
        --help|-h)
            awk '/^#/{if(NR>1)print; next} {exit}' "$0" | sed 's/^# //' | sed 's/^#//'
            exit 0
            ;;
        *) die "Unknown option: $1. Use --help for usage." ;;
    esac
done

# ── Config ──────────────────────────────────────────────────────────

if [[ -f .env ]]; then
    # shellcheck source=/dev/null
    set -a; source .env; set +a
else
    die "No .env file found. Copy .env.example to .env and configure it."
fi

[[ -n "${CLOUDRON_APP:-}" ]] || die "CLOUDRON_APP is not set in .env"

# ── Pre-flight ──────────────────────────────────────────────────────

command -v cloudron >/dev/null 2>&1 || die "cloudron CLI not found in PATH"
[[ -f CloudronManifest.json ]]     || die "CloudronManifest.json not found — run from the repo root"
command -v docker >/dev/null 2>&1  || warn "docker not found — image cleanup will be skipped"

# Warn if fork working copy has changes above the cloudron bookmark
if command -v jj >/dev/null 2>&1 && [[ -d windmill/.jj ]]; then
    ahead=$(cd windmill && jj log -r 'cloudron..@' --no-graph -T 'description.first_line() ++ "\n"' 2>/dev/null || true)
    if [[ -n "$ahead" ]]; then
        warn "windmill/ working copy is ahead of the cloudron bookmark:"
        printf '  %s\n' "$ahead" >&2
        warn "The Docker build will include these uncommitted changes."
    fi
fi

# ── Build ───────────────────────────────────────────────────────────

if [[ "$FLAG_NO_BUILD" == false ]]; then
    log "Building Docker image..."
    build_args=()
    [[ "$FLAG_VERBOSE" == true ]] && build_args+=(--raw)
    cloudron build "${build_args[@]}"

    # Move the fork's cloudron bookmark to match what was built
    if command -v jj >/dev/null 2>&1 && [[ -d windmill/.jj ]]; then
        (cd windmill && jj bookmark set cloudron -r @)
        log "Moved windmill cloudron bookmark to current working copy."
    fi
else
    log "Skipping build (--no-build)."
fi

# ── Get current image info ──────────────────────────────────────────

build_info=$(cloudron build info 2>&1) || die "Failed to get build info. Has an image been built?"
CURRENT_IMAGE=$(echo "$build_info" | grep 'Image:' | awk '{print $2}')
[[ -n "$CURRENT_IMAGE" ]] || die "Could not parse image name from 'cloudron build info'"

CURRENT_TAG="${CURRENT_IMAGE##*:}"
DOCKER_REPO="${DOCKER_REPO:-${CURRENT_IMAGE%:*}}"
# Extract just the repo name (after the registry hostname)
REPO_NAME="${DOCKER_REPO#*/}"
# Extract the registry hostname
REGISTRY_HOST="${DOCKER_REPO%%/*}"

log "Image: $CURRENT_IMAGE"
log "Repo:  $DOCKER_REPO  Tag: $CURRENT_TAG"

# ── Deploy ──────────────────────────────────────────────────────────

# Use the full domain as -l value — cloudron install accepts both subdomains and full domains
if [[ "$FLAG_REINSTALL" == true ]]; then
    confirm "This will DESTROY ALL DATA at $CLOUDRON_APP. Continue?"

    log "Uninstalling $CLOUDRON_APP..."
    if cloudron uninstall --app "$CLOUDRON_APP" 2>&1; then
        log "Uninstall complete."
    else
        warn "Nothing to uninstall at $CLOUDRON_APP (app may not be installed)."
        confirm "Install fresh at $CLOUDRON_APP anyway?"
    fi

    log "Installing fresh at $CLOUDRON_APP..."
    cloudron install -l "$CLOUDRON_APP"
else
    log "Updating $CLOUDRON_APP..."
    cloudron update --app "$CLOUDRON_APP"
fi

# ── Verify ──────────────────────────────────────────────────────────

log "Verifying deployment..."
status_output=$(cloudron status --app "$CLOUDRON_APP" 2>&1) || true
run_state=$(echo "$status_output" | grep 'Run state:' | awk -F'\t' '{print $NF}' | tr -d '[:space:]')

if [[ "$run_state" == "running" ]]; then
    log "App is running at https://$CLOUDRON_APP"
else
    warn "App run state is '$run_state' (expected 'running'). Check logs:"
    warn "  cloudron logs --app $CLOUDRON_APP"
fi

# ── Cleanup: local images ──────────────────────────────────────────

cleanup_local_count=0
if command -v docker >/dev/null 2>&1; then
    log "Cleaning up old local images..."
    local_tags=$(docker images "$DOCKER_REPO" --format '{{.Tag}}' 2>/dev/null || true)
    for tag in $local_tags; do
        if [[ "$tag" != "$CURRENT_TAG" && "$tag" != "<none>" ]]; then
            if docker rmi "$DOCKER_REPO:$tag" >/dev/null 2>&1; then
                log "  Removed local: $DOCKER_REPO:$tag"
                cleanup_local_count=$((cleanup_local_count + 1))
            fi
        fi
    done
    [[ $cleanup_local_count -eq 0 ]] && log "  No old local images to clean."
fi

# ── Cleanup: remote registry ──────────────────────────────────────

cleanup_remote_count=0
registry_creds_user=""
registry_creds_pass=""

# Try to discover registry credentials from Docker credential helpers
get_registry_creds() {
    local registry_url="https://$REGISTRY_HOST"

    # Try osxkeychain first (macOS)
    if command -v docker-credential-osxkeychain >/dev/null 2>&1; then
        local cred_json
        cred_json=$(echo "$registry_url" | docker-credential-osxkeychain get 2>/dev/null || true)
        if [[ -n "$cred_json" ]]; then
            registry_creds_user=$(echo "$cred_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('Username',''))" 2>/dev/null || true)
            registry_creds_pass=$(echo "$cred_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('Secret',''))" 2>/dev/null || true)
            if [[ -n "$registry_creds_user" && -n "$registry_creds_pass" ]]; then
                return 0
            fi
        fi
    fi

    # Try desktop helper (Docker Desktop)
    if command -v docker-credential-desktop >/dev/null 2>&1; then
        local cred_json
        cred_json=$(echo "$registry_url" | docker-credential-desktop get 2>/dev/null || true)
        if [[ -n "$cred_json" ]]; then
            registry_creds_user=$(echo "$cred_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('Username',''))" 2>/dev/null || true)
            registry_creds_pass=$(echo "$cred_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('Secret',''))" 2>/dev/null || true)
            if [[ -n "$registry_creds_user" && -n "$registry_creds_pass" ]]; then
                return 0
            fi
        fi
    fi

    return 1
}

if get_registry_creds; then
    log "Cleaning up old remote registry tags..."
    remote_tags_json=$(curl -sf -u "$registry_creds_user:$registry_creds_pass" \
        "https://$REGISTRY_HOST/v2/$REPO_NAME/tags/list" 2>/dev/null || true)

    if [[ -n "$remote_tags_json" ]]; then
        remote_tags=$(echo "$remote_tags_json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for tag in data.get('tags', []):
    print(tag)
" 2>/dev/null || true)

        for tag in $remote_tags; do
            if [[ "$tag" != "$CURRENT_TAG" ]]; then
                # Get manifest digest
                digest=$(curl -sf -u "$registry_creds_user:$registry_creds_pass" \
                    -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
                    -I "https://$REGISTRY_HOST/v2/$REPO_NAME/manifests/$tag" 2>/dev/null \
                    | grep -i 'docker-content-digest' | awk '{print $2}' | tr -d '\r' || true)

                if [[ -n "$digest" ]]; then
                    http_code=$(curl -sf -u "$registry_creds_user:$registry_creds_pass" \
                        -X DELETE "https://$REGISTRY_HOST/v2/$REPO_NAME/manifests/$digest" \
                        -w '%{http_code}' -o /dev/null 2>/dev/null || echo "000")
                    if [[ "$http_code" == "202" || "$http_code" == "404" ]]; then
                        log "  Removed remote: $tag"
                        cleanup_remote_count=$((cleanup_remote_count + 1))
                    else
                        warn "  Failed to delete remote tag $tag (HTTP $http_code)"
                    fi
                else
                    warn "  Could not get digest for remote tag $tag"
                fi
            fi
        done
        [[ $cleanup_remote_count -eq 0 ]] && log "  No old remote tags to clean."
    else
        warn "  Could not list remote tags (API call failed)."
    fi
else
    warn "Could not discover registry credentials — skipping remote cleanup."
    warn "Ensure you are logged in: docker login $REGISTRY_HOST"
fi

# ── Cleanup: registry GC ──────────────────────────────────────────

if [[ -n "${REGISTRY_APP:-}" && $cleanup_remote_count -gt 0 ]]; then
    log "Running registry garbage collection on $REGISTRY_APP..."
    if cloudron exec --app "$REGISTRY_APP" -- \
        /app/code/registry garbage-collect \
        --delete-untagged /app/data/config.yml >/dev/null 2>&1; then
        log "  Registry GC completed."
    else
        warn "  Registry GC failed. Run manually:"
        warn "  cloudron exec --app $REGISTRY_APP -- /app/code/registry garbage-collect --delete-untagged /app/data/config.yml"
    fi
elif [[ -z "${REGISTRY_APP:-}" && $cleanup_remote_count -gt 0 ]]; then
    log "Set REGISTRY_APP in .env to enable blob garbage collection."
fi

# ── Summary ─────────────────────────────────────────────────────────

log ""
log "═══════════════════════════════════════════════════"
log "  Deploy complete"
log "  Image:   $CURRENT_TAG"
log "  App:     https://$CLOUDRON_APP"
log "  Cleaned: $cleanup_local_count local, $cleanup_remote_count remote"
log "═══════════════════════════════════════════════════"
