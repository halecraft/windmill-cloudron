#!/bin/bash
set -euxo pipefail

echo "=== Diagnostic: uname -a ==="
uname -a
echo "=== Diagnostic: arch ==="
arch
echo "=== Diagnostic: /app/code contents ==="
ls -l /app/code || true
echo "=== Diagnostic: Caddy binary location ==="
which caddy || true
echo "=== Diagnostic: Caddy version ==="
caddy version || true
echo "=== Diagnostic: Caddyfile permissions ==="
ls -l /app/code/Caddyfile || true

# Set up internal addresses and ports
export WINDMILL_SERVER_INTERNAL_ADDR="127.0.0.1:8001"
export LSP_SERVER_INTERNAL_ADDR="windmill-lsp-service:3001"

# Ensure lsp_cache directory exists and is owned by cloudron
mkdir -p /app/data/lsp_cache
chown -R cloudron:cloudron /app/data/lsp_cache

# First run initialization
if [[ ! -f /app/data/.initialized_windmill ]]; then
    echo "First run: initializing /app/data..."

    # Copy any default data from /tmp/data (if any)
    if [ -d /tmp/data ]; then
        cp -r /tmp/data/* /app/data/ 2>/dev/null || true
    fi

    touch /app/data/.initialized_windmill
    echo "Initialization complete."
fi

# Handle custom CA certificates if present
if [ -d /app/data/ca-certs ] && compgen -G "/app/data/ca-certs/*.crt" > /dev/null; then
    echo "Installing custom CA certificates..."
    cp /app/data/ca-certs/*.crt /usr/local/share/ca-certificates/
    update-ca-certificates
    export DENO_TLS_CA_STORE=system,mozilla
    export REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
    export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
fi

echo "Permissions set, proceeding to LSP container management..."

set +e
echo "=== Entering LSP container management block ==="

# Start or ensure LSP container is running
LSP_CONTAINER_NAME="windmill-lsp-service"
LSP_IMAGE="ghcr.io/windmill-labs/windmill-lsp:latest"
LSP_PORT=3001
LSP_CACHE_PATH="/app/data/lsp_cache"
LSP_CACHE_TARGET="/pyls/.cache"

# Use Cloudron's Docker host
DOCKER="docker --host \"${CLOUDRON_DOCKER_HOST:-unix:///var/run/docker.sock}\""

# Check if container is running
if ! eval $DOCKER ps --format '{{.Names}}' | grep -q "^${LSP_CONTAINER_NAME}\$"; then
    echo "Starting LSP container: $LSP_CONTAINER_NAME"
    # Remove any stopped container with the same name
    if eval $DOCKER ps -a --format '{{.Names}}' | grep -q "^${LSP_CONTAINER_NAME}\$"; then
        eval $DOCKER rm -f "$LSP_CONTAINER_NAME"
    fi
    # Pull latest image
    eval $DOCKER pull "$LSP_IMAGE"
    # Get the current container's network
    NETWORK=$(
        eval $DOCKER network ls --filter "name=cloudron" --format '{{.Name}}' | head -n1
    )
    if [ -z "$NETWORK" ]; then
        NETWORK="bridge"
    fi
    # Start the LSP container
    eval $DOCKER run -d \
        --name "$LSP_CONTAINER_NAME" \
        --network "$NETWORK" \
        -p 127.0.0.1:${LSP_PORT}:3001 \
        -v "${LSP_CACHE_PATH}:${LSP_CACHE_TARGET}" \
        -e XDG_CACHE_HOME="${LSP_CACHE_TARGET}" \
        --restart always \
        "$LSP_IMAGE"
else
    echo "LSP container already running."
fi

echo "=== Exiting LSP container management block ==="
set -e

# Start supervisord
echo "Starting supervisord..."
exec /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf
