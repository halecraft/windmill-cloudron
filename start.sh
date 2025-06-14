#!/bin/bash
set -eu

# Set up internal addresses and ports
export WINDMILL_SERVER_INTERNAL_ADDR="127.0.0.1:8001"
export LSP_SERVER_INTERNAL_ADDR="127.0.0.1:3002"
export INTERNAL_CADDY_HTTP_LISTEN_PORT="${CLOUDRON_HTTP_PORT:-8000}"

# Wait for PostgreSQL to be available
echo "Waiting for PostgreSQL to be available..."
until pg_isready -h "$CLOUDRON_POSTGRESQL_HOST" -p "$CLOUDRON_POSTGRESQL_PORT" -U "$CLOUDRON_POSTGRESQL_USERNAME"; do
    sleep 2
done
echo "PostgreSQL is available."

# First run initialization
if [[ ! -f /app/data/.initialized_windmill ]]; then
    echo "First run: initializing /app/data and database roles..."

    # Copy any default data from /tmp/data (if any)
    if [ -d /tmp/data ]; then
        cp -r /tmp/data/* /app/data/ 2>/dev/null || true
    fi

    # Initialize DB roles for Windmill
    echo "Setting up Windmill DB roles..."
    psql -v ON_ERROR_STOP=1 \
        --username "$CLOUDRON_POSTGRESQL_USERNAME" \
        --host "$CLOUDRON_POSTGRESQL_HOST" \
        --port "$CLOUDRON_POSTGRESQL_PORT" \
        -d "$CLOUDRON_POSTGRESQL_DATABASE" <<EOF
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'windmill_admin') THEN
        CREATE ROLE windmill_admin NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'windmill_user') THEN
        CREATE ROLE windmill_user NOLOGIN;
    END IF;
END
\$\$;
GRANT windmill_admin TO "$CLOUDRON_POSTGRESQL_USERNAME";
GRANT windmill_user TO "$CLOUDRON_POSTGRESQL_USERNAME";
EOF

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

# Set permissions
chown -R cloudron:cloudron /app/data /run/windmill /tmp

# Start supervisord
echo "Starting supervisord..."
exec /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf
