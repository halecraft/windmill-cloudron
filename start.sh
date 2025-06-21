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

# PostgreSQL configuration
PGDATA="/app/data/postgresql"
DB_NAME="windmill"
DB_USER="windmill_admin"

# Use stored password if it exists, otherwise generate a new one
PASSWORD_FILE="/app/data/.db_password"
if [ -f "$PASSWORD_FILE" ]; then
    DB_PASSWORD=$(cat "$PASSWORD_FILE")
    echo "Using existing database password from $PASSWORD_FILE"
else
    DB_PASSWORD="windmill_secure_$(openssl rand -hex 16)"
    echo "$DB_PASSWORD" > "$PASSWORD_FILE"
    chmod 600 "$PASSWORD_FILE"
    echo "Generated new database password and stored in $PASSWORD_FILE"
fi

# Set up internal addresses and ports
export WINDMILL_SERVER_INTERNAL_ADDR="127.0.0.1:8001"
export LSP_SERVER_INTERNAL_ADDR="windmill-lsp-service:3001"

# Set database connection URL for Windmill
export DATABASE_URL="postgres://$DB_USER:$DB_PASSWORD@127.0.0.1:5432/$DB_NAME"

# Ensure lsp_cache directory exists and is owned by cloudron
mkdir -p /app/data/lsp_cache
chown -R cloudron:cloudron /app/data/lsp_cache

# PostgreSQL initialization
echo "=== PostgreSQL Setup ==="
echo "PostgreSQL data directory: $PGDATA"
echo "Checking if /app/data exists..."
ls -la /app/data/ || echo "/app/data does not exist"

if [ ! -f "$PGDATA/PG_VERSION" ]; then
    echo "Initializing PostgreSQL database..."
    
    # Ensure PostgreSQL data directory exists and is owned by postgres user
    echo "Creating PostgreSQL data directory..."
    mkdir -p /app/data/postgresql
    echo "Setting ownership of PostgreSQL data directory..."
    chown -R postgres:postgres /app/data/postgresql
    echo "PostgreSQL directory created and ownership set."
    ls -la /app/data/postgresql || echo "Failed to list PostgreSQL directory"
    
    # Initialize PostgreSQL
    gosu postgres /usr/lib/postgresql/14/bin/initdb -D "$PGDATA" --auth-local=trust --auth-host=md5
    
    # Configure PostgreSQL
    echo "host all all 127.0.0.1/32 md5" >> "$PGDATA/pg_hba.conf"
    echo "local all all trust" >> "$PGDATA/pg_hba.conf"
    echo "listen_addresses = '127.0.0.1'" >> "$PGDATA/postgresql.conf"
    echo "port = 5432" >> "$PGDATA/postgresql.conf"
    
    # Start PostgreSQL temporarily for setup
    echo "Starting PostgreSQL for initial setup..."
    gosu postgres /usr/lib/postgresql/14/bin/pg_ctl -D "$PGDATA" -o "-c listen_addresses='127.0.0.1' -c port=5432" -w start
    
    # Wait for PostgreSQL to be ready
    sleep 3
    
    # Create user and database
    echo "Creating database user and database..."
    gosu postgres /usr/lib/postgresql/14/bin/psql -c "CREATE USER $DB_USER WITH PASSWORD '$DB_PASSWORD' SUPERUSER;"
    gosu postgres /usr/lib/postgresql/14/bin/psql -c "CREATE DATABASE $DB_NAME WITH OWNER $DB_USER;"
    
    # Apply Windmill initialization script
    echo "Applying Windmill database initialization..."
    gosu postgres /usr/lib/postgresql/14/bin/psql -d "$DB_NAME" -f /app/code/init-db-as-superuser.sql
    
    # Stop PostgreSQL to restart it properly via supervisord
    echo "Stopping PostgreSQL temporary instance..."
    gosu postgres /usr/lib/postgresql/14/bin/pg_ctl -D "$PGDATA" -m fast -w stop
    
    echo "PostgreSQL initialization complete."
else
    echo "PostgreSQL data directory already exists, skipping initialization."
fi

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
