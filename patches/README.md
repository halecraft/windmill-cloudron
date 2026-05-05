# Windmill OSS Patches

These patches are applied during Docker build by the **patcher stage** in the `Dockerfile`.
They modify windmill's `*_oss.rs` stub files to restore functionality that was moved behind
the `private` (EE) feature flag.

Built against: **windmill v1.690.0** with `--features oss_core,all_languages`

## Patch Descriptions

### 001-remove-limits.patch

Removes artificial workspace and group limits from the OSS build.

**Files modified:**
- `backend/windmill-api-workspaces/src/workspaces.rs` — `_check_nb_of_workspaces()`: was limited to 2 workspaces (cfg: `not(feature = "enterprise")`)
- `backend/windmill-api-groups/src/groups.rs` — `_check_nb_of_groups()`: was limited to 3 groups (cfg: `not(feature = "enterprise")`)

Both functions are replaced with `Ok(())`.

> Note: The user limit (`check_nb_of_user()` in `oauth2_oss.rs`) is also patched to `Ok(())`,
> but that change is included in `002-restore-oauth.patch` since it modifies the same file.
> The user limit function is currently dead code (never called in OSS), but patched defensively.

### 002-restore-oauth.patch

Restores OAuth login provider wiring so SSO login works end-to-end.

**File modified:** `backend/windmill-api/src/oauth2_oss.rs`

Changes:
- **`build_oauth_clients()`** — delegates to the real `windmill_oauth::build_oauth_clients()` with `include_str!` for `oauth_connect.json` / `oauth_login.json` (same pattern as `oauth_refresh_oss.rs`)
- **`list_logins()`** — returns configured providers from `OAUTH_CLIENTS` with `{type, display_name}` format (was hardcoded empty `Vec<String>`)
- **`GET /login/{client_name}`** — new route; redirects to provider's auth URL via `windmill_oauth::oauth_redirect()`
- **`POST /login_callback/{client_name}`** — new route; exchanges code for token, fetches user email, finds-or-creates user in `password` table, creates session token
- **`check_nb_of_user()`** — replaced with `Ok(())` (limit removal)

OAuth connect routes (for resource connections) are **not** included — only the login flow.

### 003-restore-audit-logs.patch

Restores audit log recording and querying.

**File modified:** `backend/windmill-audit/src/audit_oss.rs`

Changes:
- **`audit_log()`** — inserts into `audit_partitioned` table (the new daily-partitioned table, per migration `20260311100000`)
- **`list_audit()`** — queries with `UNION ALL` across `audit_partitioned` and legacy `audit` table, with dynamic filters via `sql_builder`
- **`get_audit()`** — fetches by id from both tables

### 004-implement-email.patch

Implements email sending using the `mail-send` crate (already compiled via `smtp` feature in `oss_core`).

**File modified:** `backend/windmill-common/src/email_oss.rs`

Changes:
- **`send_email()`** / **`send_email_html()`** — sends HTML email via SMTP
- **`send_email_plain_text()`** — sends plain text email via SMTP
- **`send_email_if_possible()`** — fire-and-forget email via `tokio::spawn`, loads config from `SMTP_CONFIG` arc-swap

### 005-remove-sso-limit-banner.patch

Removes the misleading "Limited to 10 SSO users" frontend banner. The backend limit was already
removed in `002-restore-oauth.patch` (`check_nb_of_user()` → `Ok(())`), but the frontend still
displayed the warning.

**File modified:** `frontend/src/lib/components/AuthSettings.svelte`

Changes:
- Removes the `{#if !$enterpriseLicense ...}` block that rendered an `<Alert>` with "Limited to 10 SSO users / Without EE, the number of SSO users is limited to 10. SCIM/SAML is available on EE"

### 006-fix-openrouter-default-model.patch

Changes the default OpenRouter model from a free-tier model that is constantly rate-limited
(`meta-llama/llama-3.2-3b-instruct:free`) to a reliable paid model (`deepseek/deepseek-v4-pro`).
The free model causes the AI key test during initial setup to fail with HTTP 429, misleading
users into thinking their API key is invalid.

**File modified:** `frontend/src/lib/components/copilot/lib.ts`

Changes:
- `AI_PROVIDERS.openrouter.defaultModels`: `['meta-llama/llama-3.2-3b-instruct:free']` → `['deepseek/deepseek-v4-pro']`

### 007-implement-user-mgmt.patch

Restores user creation, password hashing, and password management in the OSS build.
These are required for the initial setup wizard ("Set account & finish") and ongoing
password management.

**File modified:** `backend/windmill-api/src/users_oss.rs`

Changes:
- **`hash_password()`** — generates a random salt via `SaltString::generate(OsRng)` and hashes with `argon2::PasswordHasher`, returning the PHC string. Foundation for both `create_user` and `set_password`.
- **`create_user()`** — requires super admin, normalizes email to lowercase, hashes password, generates a unique username via `generate_instance_wide_unique_username`, INSERTs into the `password` table, writes audit log (`users.add_global`), returns `(201 CREATED, email)`.
- **`set_password()`** — hashes new password, UPDATEs `password_hash` in the `password` table, writes audit log (`users.setpassword`). Used by both self-service password change and admin-driven password reset.
- **`submit_onboarding_data()`** — changed from error to no-op success (`Ok("ok")`), preventing a spurious error toast during the onboarding telemetry step.

Transitive fixes:
- `reset_password` (magic link flow) already calls `hash_password` — now works
- `set_password_of_user` (admin resets another user's password) calls `set_password` — now works

### 008-implement-workspace-auto-invite.patch

Restores the workspace auto-invite settings endpoint. Without this, creating a workspace
with "Auto-add anyone joining" toggled on reports a failure (even though the workspace
itself is created successfully).

**File modified:** `backend/windmill-api-workspaces/src/workspaces_oss.rs`

Changes:
- **`edit_auto_invite()`** — requires workspace admin via `require_admin`, builds JSONB value `{"enabled", "operator", "mode"}` from `EditAutoInvite` fields, UPDATEs `workspace_settings.auto_invite`, writes audit log (`workspaces.edit_auto_invite`).
- **`create_service_account()`** — unchanged (intentionally EE-only, returns `BadRequest`).

## How Patches Are Applied

The Dockerfile's **patcher stage** copies patches into the source tree and applies them:

```dockerfile
COPY patches/ /windmill/patches/
RUN if ls /windmill/patches/*.patch 1>/dev/null 2>&1; then \
      cd /windmill && for p in /windmill/patches/*.patch; do \
        echo "Applying patch: $p" && git apply "$p"; \
      done; \
    fi
```

Patches use standard `git diff` format with paths relative to the windmill repo root
(e.g., `a/backend/windmill-api/src/oauth2_oss.rs`).

## Regenerating After a Windmill Version Bump

When updating the windmill submodule to a new version:

1. **Try applying existing patches:**
   ```sh
   cd windmill
   for p in ../patches/*.patch; do git apply "$p" || echo "CONFLICT: $p"; done
   ```

2. **If patches apply cleanly**, you're done. Build and test.

3. **If patches conflict**, resolve manually:
   ```sh
   cd windmill
   git checkout .                      # reset to clean
   git apply --3way ../patches/NNN-name.patch  # attempt 3-way merge
   # ... or manually edit the file to match the patch intent
   ```

4. **Regenerate the patch:**
   ```sh
   cd windmill
   git diff -- backend/path/to/modified_file.rs > ../patches/NNN-name.patch
   git checkout .                      # reset submodule
   ```

5. **Verify all patches apply cleanly together:**
   ```sh
   cd windmill
   for p in ../patches/*.patch; do git apply "$p" || echo "FAILED: $p"; done
   git diff --stat                     # verify expected changes
   git checkout .                      # reset
   ```

## Design Principles

- **Minimal surface area**: patches only touch `*_oss.rs` stub files and limit-check functions
- **No forking**: the windmill submodule tracks upstream exactly; patches are a separate layer
- **Reuse existing code**: prefer calling into `windmill-oauth` helpers over reimplementing
- **Feature-gated**: all patched code is behind `#[cfg(not(feature = "private"))]` or `#[cfg(all(feature = "oauth2", not(feature = "private")))]`, so patches are inert if building with the `private` feature