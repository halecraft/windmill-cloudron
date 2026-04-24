# Windmill — Cloudron Package Technical Documentation

This document describes the architecture, build pipeline, and operational details of the
Cloudron package for [Windmill](https://www.windmill.dev/), an open-source developer platform
for building production-grade workflows and UIs from scripts.

**Built against:** Windmill v1.690.0  
**Cloudron base image:** `cloudron/base:5.0.0`  
**Manifest ID:** `com.windmill-labs.cloudronapp`

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Why Embedded PostgreSQL](#2-why-embedded-postgresql)
3. [Feature Flag Landscape](#3-feature-flag-landscape)
4. [OSS Patches](#4-oss-patches)
5. [OIDC / SSO Integration](#5-oidc--sso-integration)
6. [SMTP / Email Integration](#6-smtp--email-integration)
7. [Startup Sequence](#7-startup-sequence)
8. [Building](#8-building)
9. [How to Update Windmill](#9-how-to-update-windmill)
10. [Known Limitations](#10-known-limitations)
11. [Smoke Test Checklist](#11-smoke-test-checklist)

---

## 1. Architecture Overview

The package runs as a single Cloudron container with six supervised processes, plus one
Docker sidecar container for the language server (LSP).

### Supervised Processes

| Process               | Binary / Script              | Mode / Role              | Priority | Notes                                    |
|-----------------------|------------------------------|--------------------------|----------|------------------------------------------|
| PostgreSQL 16         | `pg_ctl` via `gosu postgres` | Database                 | 100      | Embedded, data at `/app/data/postgresql`  |
| Caddy                 | `caddy run`                  | Reverse proxy            | 200      | Listens on `:8000` (Cloudron `httpPort`)  |
| windmill-server       | `windmill`                   | `MODE=server`            | 300      | API + frontend on port 8001              |
| windmill-worker       | `windmill`                   | `MODE=worker` (default)  | 300      | `WORKER_GROUP=default`, 1 process        |
| windmill-worker-native| `windmill`                   | `MODE=worker` (native)   | 300      | `WORKER_GROUP=native`, 8 workers, 200ms sleep queue |
| credential-inject     | `inject-credentials.sh`      | One-shot                 | 400      | Injects OIDC + SMTP, then exits          |

### LSP Sidecar

The Language Server Protocol service runs as a separate Docker container (`ghcr.io/windmill-labs/windmill-lsp:latest`)
managed via Cloudron's `docker` addon. It provides editor autocompletion for Python, TypeScript,
and other languages.

- Container name: `windmill-lsp-service`
- Connected to Cloudron's Docker network
- LSP cache persisted at `/app/data/lsp_cache`
- Started by `start.sh` before supervisord takes over

### Caddy Routing

Caddy listens on port 8000 (the `httpPort` declared in `CloudronManifest.json`) and routes:

- `/ws/*` → LSP sidecar at `windmill-lsp-service:3001` (WebSocket traffic for editor autocompletion)
- `/*` → windmill-server at `127.0.0.1:8001` (all other traffic)

Both upstreams have extended timeouts (300s read/write, 30s dial) and a 250MB max request body
size for file uploads.

---

## 2. Why Embedded PostgreSQL

This package embeds PostgreSQL 16 instead of using Cloudron's PostgreSQL addon. This is not
optional — it is a fundamental requirement imposed by Windmill's security architecture.

### Windmill's Row-Level Security Model

Windmill implements tenant isolation via PostgreSQL Row-Level Security (RLS). The schema requires
two PostgreSQL roles:

- **`windmill_user`** — the unprivileged role. RLS policies on all core tables reference this role
  to enforce per-workspace data boundaries.
- **`windmill_admin`** — created with `BYPASSRLS`. The Rust backend dynamically switches between
  roles using `SET LOCAL ROLE windmill_user` and `SET LOCAL ROLE NONE` depending on whether an
  operation should be subject to tenant restrictions.

These roles are created by `init-db-as-superuser.sql`:

```sql
CREATE ROLE windmill_user;
-- ... grants ...
CREATE ROLE windmill_admin WITH BYPASSRLS;
GRANT windmill_user TO windmill_admin;
```

### The Incompatibility

This initialization script requires:

- `CREATE ROLE` privilege (to create `windmill_user` and `windmill_admin`)
- `BYPASSRLS` privilege (to grant RLS bypass to `windmill_admin`)

Cloudron's PostgreSQL addon provides a single database user with no `CREATEROLE` or `SUPERUSER`
privileges. There is no way to request elevated privileges from the addon.

This is a fundamental incompatibility — no workaround exists short of rewriting Windmill's
entire security model. Embedding PostgreSQL is the only viable approach.

### Data Persistence

PostgreSQL data is stored at `/app/data/postgresql`. Cloudron's backup system automatically
includes `/app/data`, so database contents are captured in every backup and restored correctly.

---

## 3. Feature Flag Landscape

Windmill's Rust backend uses Cargo feature flags to gate functionality across three tiers.

### Feature Tiers

| Tier       | Feature Flag | Description                                                        |
|------------|--------------|--------------------------------------------------------------------|
| **OSS**    | `oss`        | `oss_core` + `all_languages` + `no_auth`                          |
| **CE**     | `ce`         | Community Edition — all OSS features plus some additional ones     |
| **EE**     | `enterprise` | Enterprise Edition — full feature set, requires license key        |
| **Private**| `private`    | EE internals — requires proprietary `windmill-ee-private` repo     |

### What `oss_core` Includes

The `oss_core` feature enables the following sub-features:

`embedding`, `parquet`, `openidconnect`, `license`, `http_trigger`, `zip`, `oauth2`,
`postgres_trigger`, `mqtt_trigger`, `websocket`, `smtp`, `native_trigger`, `static_frontend`,
`mcp`, `bedrock`, `run_inline`, `quickjs`

### The `no_auth` Problem

The composite `oss` feature is defined as `oss_core + all_languages + no_auth`. The `no_auth`
feature is critically broken for production use:

- It short-circuits the login endpoint to return `"no_auth"` instead of creating a session token
- No cookies are set, no session is established
- This causes redirect loops and breaks all authentication flows (password login, SSO, etc.)
- The official upstream OSS Docker image has this same problem

**This package builds with `oss_core,all_languages` explicitly, dropping `no_auth`.** This is
one of the key differentiators from the official OSS image.

### The `private` Gate

The `private` feature flag gates code that lives in the proprietary `windmill-ee-private`
repository. We cannot compile with this feature because the repository is not publicly
accessible. Functionality behind `private` includes: OAuth login wiring, audit log
implementation, email sending, git sync, S3 helpers, SAML, and more. Our patches restore
the most critical subset of this functionality.

---

## 4. OSS Patches

### Background: The EE Refactor

In June 2025, Windmill underwent a major restructuring (commit `0e316239dd`, PR #5844) that
moved substantial functionality from the open-source codebase behind the `private` feature flag.
This included OAuth login, audit log recording/querying, S3 storage helpers, and git sync.

The affected code was replaced with stub files (`*_oss.rs`) that return errors or empty results.
For example, `oauth2_oss.rs` returns an empty provider list, `audit_oss.rs` silently discards
audit events, and `email_oss.rs` does nothing.

In January 2026, the `windmill-oauth` crate was released as open source, restoring the OAuth
*implementation* — but the wiring stub in `oauth2_oss.rs` was never updated to call it. The
crate exists and compiles, but the OSS build ignores it.

Our patches bridge this gap by wiring the stubs to the real implementations.

### Patch Summary

| Patch | Purpose | Files Modified |
|-------|---------|----------------|
| `001-remove-limits.patch` | Removes workspace (2) and group (3) caps | `workspaces.rs`, `groups.rs` |
| `002-restore-oauth.patch` | Wires `oauth2_oss.rs` to call `windmill-oauth` — full OAuth login/callback flow; removes SSO user limit (10→unlimited) | `oauth2_oss.rs` |
| `003-restore-audit-logs.patch` | Restores audit log write/read/list | `audit_oss.rs` |
| `004-implement-email.patch` | Implements `send_email()` using `mail-send` crate | `email_oss.rs` |
| `005-remove-sso-limit-banner.patch` | Removes frontend banner about SSO user limits | `AuthSettings.svelte` |
| `006-fix-openrouter-default-model.patch` | Fixes default AI model name for OpenRouter | `lib.ts` |
| `007-implement-user-mgmt.patch` | Implements `create_user`, `set_password`, `hash_password` | `users_oss.rs` |
| `008-implement-workspace-auto-invite.patch` | Implements `edit_auto_invite` | `workspaces_oss.rs` |

For detailed descriptions of every function changed, see [`patches/README.md`](patches/README.md).

### Writing New Patches — Rules

1. **Use runtime `sqlx::query().bind()`, never compile-time `sqlx::query!()`.**
   The `.sqlx/` offline cache only has entries for upstream queries. Adding a new
   `sqlx::query!()` macro invocation will fail at compile time because the offline
   cache won't have a matching entry.

2. **Gate all new code with `#[cfg(not(feature = "private"))]`.**
   This ensures patches are inert if someone builds with the `private` feature, preventing
   conflicts with the proprietary implementation.

3. **Generate patches via `git diff` in the windmill submodule, not by hand-editing patch files.**
   Hand-editing patch files is error-prone and produces malformed hunks.

4. **Verify all patches apply together:**
   ```sh
   cd windmill
   for p in ../patches/*.patch; do git apply --check "$p" && echo "OK: $(basename $p)"; done
   ```

5. **Reset the submodule after generating:**
   ```sh
   cd windmill && git checkout .
   ```

### How to Regenerate Patches After a Windmill Version Bump

When updating the windmill submodule to a new version, existing patches may not apply
cleanly due to upstream changes in the same files.

1. **Try applying existing patches:**
   ```sh
   cd windmill
   for p in ../patches/*.patch; do git apply "$p" || echo "CONFLICT: $p"; done
   ```

2. **If patches apply cleanly**, you're done. Build and test.

3. **If patches conflict**, resolve manually:
   ```sh
   cd windmill
   git checkout .                                    # reset to clean
   git apply --3way ../patches/NNN-name.patch        # attempt 3-way merge
   # ... or manually edit the file to match the patch intent
   ```

4. **Regenerate the patch:**
   ```sh
   cd windmill
   git diff -- backend/path/to/modified_file.rs > ../patches/NNN-name.patch
   git checkout .                                    # reset submodule
   ```

5. **Verify all patches apply cleanly together:**
   ```sh
   cd windmill
   for p in ../patches/*.patch; do git apply "$p" || echo "FAILED: $p"; done
   git diff --stat                                   # verify expected changes
   git checkout .                                    # reset
   ```

---

## 5. OIDC / SSO Integration

Cloudron SSO is integrated through two complementary mechanisms: database credential injection
(runtime) and compiled OAuth client wiring (build-time patch).

### Credential Injection

The `inject-credentials.sh` script runs as a supervisord one-shot process at priority 400.
It performs the following:

1. **Polls for PostgreSQL connectivity** — retries every 2 seconds until `psql -c "SELECT 1"`
   succeeds or 120 seconds elapse.
2. **Polls for `global_settings` table** — this table is created by windmill's migration system
   during first boot. The script checks `SELECT to_regclass('public.global_settings')` until it
   returns a non-null result.
3. **Upserts the `oauths` key** in `global_settings` with a `"cloudron"` provider entry
   containing `client_id`, `client_secret`, `display_name`, and a `login_config` object with
   `auth_url`, `token_url`, `userinfo_url`, and `scopes`.

The upsert uses PostgreSQL's `||` (JSONB merge) operator on conflict:

```sql
ON CONFLICT (name) DO UPDATE
SET value = global_settings.value || jsonb_build_object('cloudron', ...)
```

This preserves any other OAuth providers that have been manually configured through
Windmill's UI.

### How Windmill Picks Up Injected Credentials

The `global_settings` table has an `AFTER INSERT OR UPDATE` NOTIFY trigger. When
`inject-credentials.sh` upserts the `oauths` key, PostgreSQL sends a notification on the
`global_settings_notify` channel. The windmill-server process listens on this channel and
reloads OAuth configuration within seconds — no restart required.

### The Patched OAuth Client (Patch 002)

The injected credentials are consumed by the patched `build_oauth_clients()` function in
`oauth2_oss.rs`. Windmill's OAuth system has two paths for constructing OAuth clients:

- **Path A** — providers listed in the compiled-in `oauth_login.json` (Google, GitHub, etc.)
- **Path B** — providers with an embedded `login_config` object in their database entry

Since `"cloudron"` is not in the compiled-in `oauth_login.json`, the injected entry includes
a full `login_config` with auth/token/userinfo URLs. The patched code reads this from the
database and constructs the OAuth client via Path B.

### Callback URL

The callback URL is `/user/login_callback/cloudron`, which must match the `loginRedirectUri`
in `CloudronManifest.json`. Cloudron registers this URL with its OIDC provider during app
installation.

### Credential Lifecycle

- Credentials are refreshed on every container restart, handling Cloudron credential rotation
- The `display_name` is set to `"Cloudron"`
- Cloudron provides `CLOUDRON_OIDC_PROVIDER_NAME` (e.g., the instance name) which could be
  used as the display name in a future enhancement

### Install Behavior

- `cloudron install` (default, without `--no-sso`) provisions the OIDC addon and provides
  `CLOUDRON_OIDC_*` environment variables. SSO will be configured automatically.
- `cloudron install --no-sso` suppresses the OIDC environment variables entirely. The
  credential injection script detects the missing `CLOUDRON_OIDC_ISSUER` and skips OIDC setup.
- Always install **without** `--no-sso` for Cloudron SSO integration.

---

## 6. SMTP / Email Integration

### Credential Injection

`inject-credentials.sh` upserts the `global_settings` key `"smtp_settings"` with Cloudron's
SMTP credentials (`CLOUDRON_MAIL_SMTP_SERVER`, `CLOUDRON_MAIL_SMTP_PORT`,
`CLOUDRON_MAIL_SMTP_USERNAME`, `CLOUDRON_MAIL_SMTP_PASSWORD`, `CLOUDRON_MAIL_FROM`).

### TLS Configuration

Cloudron's sendmail relay has TLS/STARTTLS disabled. The injected settings reflect this:

- `smtp_tls_implicit`: `false`
- `smtp_disable_tls`: `true`

### Belt-and-Suspenders: Environment Variables

SMTP credentials are also passed as `SMTP_*` environment variables to the windmill-server
process via supervisord. This serves as a fallback — windmill reads SMTP config from the
database first, but falls back to environment variables if the database entry is missing.

### Important Asymmetry with OIDC

SMTP injection uses `SET value = EXCLUDED.value` (full replace) on conflict, unlike OIDC
which uses `||` (JSONB merge). This means:

> **Any SMTP settings configured manually through Windmill's UI will be overwritten on the
> next container restart.**

This is intentional — Cloudron owns the SMTP infrastructure, and manually configured SMTP
settings would likely break email delivery. If you need custom SMTP settings, modify
`inject-credentials.sh`.

---

## 7. Startup Sequence

The container boots in two phases: `start.sh` handles one-time setup and environment
preparation, then `exec supervisord` takes over as PID 1.

### Phase 1: `start.sh`

1. **Database password management** — generates a random password on first run and stores it
   at `/app/data/.db_password`. On subsequent boots, reads the existing password. This ensures
   the password survives container restarts and is consistent between PostgreSQL and
   windmill's `DATABASE_URL`.

2. **Environment variable setup:**
   - `DATABASE_URL` — constructed from the stored password
   - `WINDMILL_SERVER_INTERNAL_ADDR` — `127.0.0.1:8001`
   - `LSP_SERVER_INTERNAL_ADDR` — `windmill-lsp-service:3001`
   - SMTP fallback variables — set to empty strings if not provided by Cloudron, so
     supervisord's `%(ENV_...)s` interpolation syntax doesn't crash on missing variables

3. **First-run PostgreSQL initialization** (only if `/app/data/postgresql/PG_VERSION` does
   not exist):
   - `initdb` with `--auth-local=trust --auth-host=md5`
   - Configure `pg_hba.conf` for local trust + remote md5
   - Start PostgreSQL temporarily
   - `CREATE USER windmill_admin WITH PASSWORD '...' SUPERUSER`
   - `CREATE DATABASE windmill WITH OWNER windmill_admin`
   - Run `init-db-as-superuser.sql` (creates `windmill_user` and `windmill_admin` roles)
   - Stop PostgreSQL (it will be restarted by supervisord)

4. **Custom CA certificates** — if `/app/data/ca-certs/*.crt` files exist, they are installed
   into the system CA store and relevant environment variables are set.

5. **LSP container management:**
   - Acquire lock file (`/app/data/lsp_management.lock`) with stale-lock detection via PID check
   - Stop and remove any existing `windmill-lsp-service` container
   - Pull latest `ghcr.io/windmill-labs/windmill-lsp:latest` image
   - Start new container on Cloudron's Docker network with the LSP cache volume mounted
   - Release lock file

6. **`exec /usr/bin/supervisord`** — replaces the shell process. Supervisord becomes PID 1.

### Phase 2: supervisord

Processes start in priority order:

| Priority | Process(es)                                              | Behavior     |
|----------|----------------------------------------------------------|--------------|
| 100      | PostgreSQL                                               | autorestart  |
| 200      | Caddy                                                    | autorestart  |
| 300      | windmill-server, windmill-worker, windmill-worker-native | autorestart  |
| 400      | credential-inject                                        | one-shot     |

### Timing Details

On a fresh install, the startup sequence involves a race condition by design:

1. PostgreSQL starts (priority 100)
2. windmill-server starts (priority 300) and runs database migrations, creating the
   `global_settings` table among others
3. windmill-server performs `initial_load`, reading OAuth config from `global_settings`
   — at this point, the table may be empty
4. `credential-inject` starts (priority 400), polls until `global_settings` exists, then
   upserts OIDC and SMTP credentials
5. The `global_settings` NOTIFY trigger fires, causing windmill-server to reload OAuth
   configuration within seconds

**Consequence:** The login page may briefly show no OAuth provider button. After a few
seconds, the "Cloudron" SSO button appears as the server reloads configuration.

### Failure Mode

`credential-inject` exits 0 even on timeout (by design) so supervisord does not retry it.
If credentials are not injected, the symptom is "no SSO button on the login page" or
"email sending doesn't work." A container restart fixes it. Check the container logs for
`ERROR: PostgreSQL not ready after 120s` or `ERROR: global_settings table not found after 120s`
to diagnose injection failures.

---

## 8. Building

### Standard Build

```sh
cloudron build
```

This runs `docker build` under the hood. No `--build-arg` is needed — the Dockerfile defaults
to `features="oss_core,all_languages"`.

### Dockerfile Stage Structure

```
runtime-bin-stages (deno, bun, php, composer, docker)
        │
    patcher ─── applies patches, prepares .git for version embedding
        │
   rust_base ─── shared Rust toolchain (mold, sccache, cargo-chef)
    ┌───┼───┐
    │   │   │
    │   │   └── duckdb_ffi_builder ── builds libwindmill_duckdb_ffi_internal.so
    │   │
    │   └── frontend ── npm ci && npm run build (Svelte static assets)
    │
    ├── planner ── cargo chef prepare (generates recipe.json)
    │
    └── builder ── cargo chef cook + cargo build --release --features oss_core,all_languages
            │
         final ── cloudron/base:5.0.0 + PostgreSQL 16 + Caddy + runtime deps
```

### Building on Apple Silicon (arm64)

The Dockerfile handles cross-architecture builds transparently. The key issue:
`COPY --from=<bare-image-name>` (not a named build stage) resolves the image using the
**build host's platform**, not the target stage's platform. On an arm64 Mac building for
amd64 Cloudron, this silently copies arm64 binaries into an amd64 container.

The solution: all external runtime binary sources are declared as named stages with
`FROM --platform=linux/amd64`:

```dockerfile
FROM --platform=linux/amd64 denoland/deno:2.2.1 AS deno-bin
FROM --platform=linux/amd64 oven/bun:1.3.10 AS bun-bin
FROM --platform=linux/amd64 php:8.3.30-cli-bookworm AS php-bin
FROM --platform=linux/amd64 composer:2.9.5 AS composer-bin
FROM --platform=linux/amd64 docker:29-dind AS docker-bin
```

`COPY --from=deno-bin` references a named stage, which respects the stage's `--platform`
declaration regardless of the build host.

**What's NOT affected:**

- The windmill binary and DuckDB `.so` are built inside named stages that already specify
  `FROM --platform=linux/amd64`
- Go is downloaded via `curl` with an explicit `linux-amd64.tar.gz` URL
- Node.js and uv are installed inside the amd64 base image via `apt` and `curl`

---

## 9. How to Update Windmill

1. **Update the submodule:**
   ```sh
   cd windmill
   git fetch --tags
   git checkout v<new_version>
   ```

2. **Re-apply patches:**
   ```sh
   for p in ../patches/*.patch; do git apply "$p" || echo "CONFLICT: $p"; done
   ```

3. **Fix any patch conflicts.** Most likely in `*_oss.rs` files if function signatures changed.
   See [How to Regenerate Patches](#how-to-regenerate-patches-after-a-windmill-version-bump)
   for the resolution workflow.

4. **Regenerate patches from the fixed state:**
   ```sh
   cd windmill
   git diff -- backend/path/to/modified_file.rs > ../patches/NNN-name.patch
   ```

5. **Reset submodule:**
   ```sh
   cd windmill && git checkout .
   ```

6. **Update `upstreamVersion` in `CloudronManifest.json`:**
   ```json
   "upstreamVersion": "<new_version>"
   ```

7. **Build:**
   ```sh
   cloudron build
   ```

8. **Deploy:**
   ```sh
   cloudron update --app windmill.example.com
   ```

---

## 10. Known Limitations

### Not Available (by design or omission)

| Feature | Reason |
|---------|--------|
| nsjail sandbox | Omitted from build. Workers check `NSJAIL_AVAILABLE` at runtime and gracefully degrade to running scripts without sandboxing. |
| High availability / multi-node | Single-instance only — no HA, no distributed workers |
| Multiplayer editing | Enterprise Edition only |
| Git sync | Implementation is in the private repo |
| External triggers: Kafka, NATS, SQS, GCP Pub/Sub, Azure Event Hub | All EE |
| S3 / object store helpers for jobs | EE |
| External secret backends: Vault, AWS Secrets Manager, Azure Key Vault | EE |
| Full-text search / Tantivy indexer | EE |
| OpenTelemetry export | EE |
| Autoscaling | EE, Kubernetes-oriented |
| SAML SSO | EE — Cloudron provides OIDC instead |
| Concurrency limits | EE |
| Email triggers (inbound SMTP server) | Gated behind `private` |

### Cosmetic Issues

- **In-app AI documentation assistant** — `POST /api/inkeep` shows an "Error getting
  documentation" toast. This is cosmetic; the AI code assistant still works, it just lacks
  Windmill-specific docs context. Inkeep is a paid EE integration.

### Operational Caveats

- **PostgreSQL major-version upgrades** — if upgrading from an older installation that used
  PostgreSQL 14, the data directory format is incompatible with PostgreSQL 16. A manual
  `pg_upgrade` is required. New installations start with PostgreSQL 16 and are unaffected.

---

## 11. Smoke Test Checklist

After deploying or updating, verify the following:

- [ ] **Login page loads** at the app URL
- [ ] **"Cloudron" SSO button appears** (if installed without `--no-sso`)
- [ ] **SSO login flow completes** — redirects back, session is created
- [ ] **Default admin login works** — `admin@windmill.dev` / `changeme`
- [ ] **Can create a workspace**
- [ ] **Can create and run a Python script**
- [ ] **Can create and run a TypeScript/Deno script**
- [ ] **LSP autocompletion works** in the script editor
- [ ] **Email sending works** — test via a script or flow notification
- [ ] **Audit logs are recorded** — check Settings → Audit Logs