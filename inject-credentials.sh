#!/bin/bash
# =============================================================================
# Cloudron Credential Injection (supervisord one-shot)
# Injects OIDC and SMTP credentials into windmill's global_settings table.
# Runs on every boot so rotated credentials are always current.
#
# This script is launched by supervisord at priority 400, after:
#   - PostgreSQL (priority 100)
#   - windmill-server (priority 300, runs DB migrations on first boot)
#
# It polls until the global_settings table exists (created by windmill's
# migration system), then upserts credentials and exits. The global_settings
# NOTIFY trigger causes windmill to reload oauths/SMTP within seconds.
#
# Context: jj:komtolus
# =============================================================================
set -euo pipefail

DB_NAME="windmill"
MAX_WAIT=120  # seconds to wait for PG + migrations before giving up
POLL_INTERVAL=2

echo "=== Cloudron Credential Injection ==="

# ---------------------------------------------------------------------------
# Wait for PostgreSQL to accept connections
# ---------------------------------------------------------------------------
elapsed=0
echo "Waiting for PostgreSQL to be ready..."
while ! gosu postgres psql -d "$DB_NAME" -c "SELECT 1" >/dev/null 2>&1; do
    elapsed=$((elapsed + POLL_INTERVAL))
    if [ "$elapsed" -ge "$MAX_WAIT" ]; then
        echo "ERROR: PostgreSQL not ready after ${MAX_WAIT}s — skipping credential injection."
        exit 0  # exit 0 so supervisord doesn't retry
    fi
    sleep "$POLL_INTERVAL"
done
echo "PostgreSQL is ready (waited ${elapsed}s)."

# ---------------------------------------------------------------------------
# Wait for global_settings table to exist (windmill migrations)
# ---------------------------------------------------------------------------
echo "Waiting for global_settings table (windmill migrations)..."
while true; do
    TABLE_EXISTS=$(gosu postgres psql -d "$DB_NAME" -tAc "SELECT to_regclass('public.global_settings')" 2>/dev/null || echo "")
    if [ "$TABLE_EXISTS" = "global_settings" ]; then
        break
    fi
    elapsed=$((elapsed + POLL_INTERVAL))
    if [ "$elapsed" -ge "$MAX_WAIT" ]; then
        echo "ERROR: global_settings table not found after ${MAX_WAIT}s — skipping credential injection."
        exit 0
    fi
    sleep "$POLL_INTERVAL"
done
echo "global_settings table exists (waited ${elapsed}s total)."

# ---------------------------------------------------------------------------
# OIDC credential injection
# ---------------------------------------------------------------------------
if [ -n "${CLOUDRON_OIDC_ISSUER:-}" ]; then
    echo "Injecting Cloudron OIDC credentials into windmill..."
    gosu postgres psql -d "$DB_NAME" -c "
        INSERT INTO global_settings (name, value)
        VALUES ('oauths', jsonb_build_object('cloudron', jsonb_build_object(
            'id', '${CLOUDRON_OIDC_CLIENT_ID}'::text,
            'secret', '${CLOUDRON_OIDC_CLIENT_SECRET}'::text,
            'display_name', 'Cloudron',
            'login_config', jsonb_build_object(
                'auth_url', '${CLOUDRON_OIDC_AUTH_ENDPOINT}'::text,
                'token_url', '${CLOUDRON_OIDC_TOKEN_ENDPOINT}'::text,
                'userinfo_url', '${CLOUDRON_OIDC_PROFILE_ENDPOINT}'::text,
                'scopes', jsonb_build_array('openid', 'profile', 'email')
            )
        )))
        ON CONFLICT (name) DO UPDATE
        SET value = global_settings.value || jsonb_build_object('cloudron', jsonb_build_object(
            'id', '${CLOUDRON_OIDC_CLIENT_ID}'::text,
            'secret', '${CLOUDRON_OIDC_CLIENT_SECRET}'::text,
            'display_name', 'Cloudron',
            'login_config', jsonb_build_object(
                'auth_url', '${CLOUDRON_OIDC_AUTH_ENDPOINT}'::text,
                'token_url', '${CLOUDRON_OIDC_TOKEN_ENDPOINT}'::text,
                'userinfo_url', '${CLOUDRON_OIDC_PROFILE_ENDPOINT}'::text,
                'scopes', jsonb_build_array('openid', 'profile', 'email')
            )
        ));
    "
    echo "Cloudron OIDC credentials injected."
else
    echo "CLOUDRON_OIDC_ISSUER not set — skipping OIDC injection."
fi

# ---------------------------------------------------------------------------
# SMTP credential injection
# ---------------------------------------------------------------------------
if [ -n "${CLOUDRON_MAIL_SMTP_SERVER:-}" ]; then
    echo "Injecting Cloudron SMTP settings into windmill..."
    gosu postgres psql -d "$DB_NAME" -c "
        INSERT INTO global_settings (name, value)
        VALUES ('smtp_settings', jsonb_build_object(
            'smtp_host', '${CLOUDRON_MAIL_SMTP_SERVER}'::text,
            'smtp_port', ${CLOUDRON_MAIL_SMTP_PORT:-587},
            'smtp_username', '${CLOUDRON_MAIL_SMTP_USERNAME}'::text,
            'smtp_password', '${CLOUDRON_MAIL_SMTP_PASSWORD}'::text,
            'smtp_from', '${CLOUDRON_MAIL_FROM}'::text,
            'smtp_tls_implicit', false,
            'smtp_disable_tls', true
        ))
        ON CONFLICT (name) DO UPDATE
        SET value = EXCLUDED.value;
    "
    echo "Cloudron SMTP settings injected."
else
    echo "CLOUDRON_MAIL_SMTP_SERVER not set — skipping SMTP injection."
fi

# ---------------------------------------------------------------------------
# Email domain injection
# ---------------------------------------------------------------------------
if [ -n "${CLOUDRON_MAIL_DOMAIN:-}" ]; then
    echo "Injecting email domain from Cloudron..."
    gosu postgres psql -d "$DB_NAME" -c "
        INSERT INTO global_settings (name, value)
        VALUES ('email_domain', '\"${CLOUDRON_MAIL_DOMAIN}\"'::jsonb)
        ON CONFLICT (name) DO UPDATE
        SET value = EXCLUDED.value;
    "
    echo "Email domain set to ${CLOUDRON_MAIL_DOMAIN}."
else
    echo "CLOUDRON_MAIL_DOMAIN not set — skipping email domain injection."
fi

echo "=== Credential injection complete ==="