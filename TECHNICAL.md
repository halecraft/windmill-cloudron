# Windmill — Cloudron Package Technical Documentation

This document describes the architecture, build pipeline, and operational details of the
Cloudron package for [Windmill](https://www.windmill.dev/), an open-source developer platform
for building production-grade workflows and UIs from scripts.

**Built against:** Windmill v1.695.0
**Cloudron base image:** `cloudron/base:5.0.0`  
**Manifest ID:** `com.windmill-labs.cloudronapp`

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Why Embedded PostgreSQL](#2-why-embedded-postgresql)
3. [Feature Flag Landscape](#3-feature-flag-landscape)
4. [OSS Modifications (Fork Architecture)](#4-oss-modifications-fork-architecture)
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
implementation, email sending, git sync, S3 helpers, SAML, and more. Our fork restores
the most critical subset of this functionality.

---

## 4. OSS Modifications (Fork Architecture)

### Why a Fork

In June 2025, Windmill's EE refactor (PR #5844) moved substantial functionality behind the
`private` feature flag. We restore the most critical subset in our fork. 

The fork at [halecraft/windmill](https://github.com/halecraft/windmill) carries our modifications
as a stack of jj changes on a `cloudron` bookmark, rebased onto each upstream release. Conflicts
are resolved in real source files with full IDE support.

### Branch Structure

- **`main`** — tracks `windmill-labs/windmill` upstream. Never modified directly.
- **`cloudron`** — jj bookmark at the tip of our modification stack, based on `main`.
- **`upstream`** — git remote pointing to `windmill-labs/windmill` for fetching new releases.

To inspect our modifications:

```sh
cd windmill-fork
jj log -r 'main..cloudron'
```

### Version String

The fork replaces the upstream `git_version!()` proc macro with:

```rust
pub const GIT_VERSION: &str = concat!(env!("CARGO_PKG_VERSION"), "-cloudron");
```

This produces `1.695.0-cloudron` — derived from `Cargo.toml` at compile time. On upstream
rebase, `CARGO_PKG_VERSION` updates automatically. No `.git/` directory is needed in the
Docker build context (~490MB saving).

### Modification Summary

| jj Change | Purpose | Files Modified |
|-----------|---------|----------------|
| Restore audit logs | Audit log recording, querying, and listing | `audit_oss.rs` |
| Implement email | SMTP email sending via `mail-send` crate | `email_oss.rs` |
| Implement user mgmt | `create_user`, `set_password`, `hash_password` | `users_oss.rs` |
| Workspace auto-invite | `edit_auto_invite` settings endpoint | `workspaces_oss.rs` |
| Restore OAuth + OpenRouter fix | OAuth login/callback flow; OpenRouter default model | `oauth2_oss.rs`, `copilot/lib.ts` |
| Remove limits + banners | Remove workspace (2), group (3), SSO user (10) caps; remove frontend banner | `workspaces.rs`, `groups.rs`, `oauth2_oss.rs`, `AuthSettings.svelte` |
| Version string | Replace `git_version!()` with `CARGO_PKG_VERSION`-cloudron | `utils.rs` |
| S3 object storage helpers | Workspace file browser, multipart upload, job S3 access, file download/delete/move | `job_helpers_oss.rs`, `job_s3_helpers_oss.rs`, `StorageSettings.svelte` |

### Writing New Modifications — Rules

1. **Use runtime `sqlx::query().bind()`, never compile-time `sqlx::query!()`.**
   The `.sqlx/` offline cache only has entries for upstream queries.

2. **Gate all new code with `#[cfg(not(feature = "private"))]`.**
   Ensures modifications are inert if building with the `private` feature.

3. **Add new changes to the `cloudron` bookmark stack:**
   ```sh
   cd windmill-fork
   jj new cloudron
   jj bookmark set cloudron -r @
   # ... make changes ...
   jj describe -m 'feat(oss): description of change'
   ```

4. **Prefer modifying `*_oss.rs` stub files** over mainline files. Stub files have
   near-zero upstream churn; mainline files (e.g., `workspaces.rs`) change frequently.

---

## 5. OIDC / SSO Integration

Cloudron SSO is integrated through two complementary mechanisms: database credential injection
(runtime) and compiled OAuth client wiring (build-time fork modification).

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

### The Modified OAuth Client

The injected credentials are consumed by the modified `build_oauth_clients()` function in
`oauth2_oss.rs`. Windmill's OAuth system has two paths for constructing OAuth clients:

- **Path A** — providers listed in the compiled-in `oauth_login.json` (Google, GitHub, etc.)
- **Path B** — providers with an embedded `login_config` object in their database entry

Since `"cloudron"` is not in the compiled-in `oauth_login.json`, the injected entry includes
a full `login_config` with auth/token/userinfo URLs. The modified code reads this from the
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

**Pre-build check:** Ensure `windmill-fork/` is checked out at the `cloudron` bookmark:
```sh
cd windmill-fork && jj log -r @ --no-graph -T 'bookmarks'
# Should show "cloudron"
```

This runs `docker build` under the hood. No `--build-arg` is needed — the Dockerfile defaults
to `features="oss_core,all_languages"`.

### Dockerfile Stage Structure

```
runtime-bin-stages (deno, bun, php, composer, docker)
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

Source files are copied directly from `windmill-fork/` in the build context. The fork's `.git/`
and `.jj/` directories are excluded via `.dockerignore` (~500MB saving). Version embedding uses
`CARGO_PKG_VERSION` instead of `git describe`.

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

1. **Fetch upstream releases:**
   ```sh
   cd windmill-fork
   jj git fetch --remote upstream
   ```

2. **Rebase our modifications onto the new version:**
   ```sh
   jj rebase -b cloudron -d v<new_version>
   ```

3. **Resolve any conflicts.** jj marks conflicted changes in `jj log`. Fix conflicts in
   real source files (not patch hunks), then `jj resolve` each one. Most conflicts will be
   in the "Remove limits" change at the tip of the stack (highest upstream churn).

4. **Verify the stack:**
   ```sh
   jj log -r 'main..cloudron'    # should show 7 clean changes
   ```

5. **Update the manifest version:**
   Edit `CloudronManifest.json` and set `"upstreamVersion"` to the new version.
   Note: `GIT_VERSION` in the binary updates automatically — `CARGO_PKG_VERSION` tracks
   the workspace `Cargo.toml` which upstream bumps every release.

6. **Build and deploy:**
   ```sh
   cloudron build
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
| S3 / object store helpers for jobs | ✅ Restored (AWS OIDC and advanced path permissions not supported) |
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
- [ ] **Workspace S3 bucket "Test" succeeds** in workspace settings
- [ ] **Workspace S3 file browser ("Explore") lists files**
- [ ] **Upload a file via the S3 file browser**
- [ ] **HTTP trigger accepts `multipart/form-data` file upload**
- [ ] **Flow receives `{"s3": "..."}` argument from file upload**
