# Windmill for Cloudron

An **unofficial** Cloudron package for [Windmill](https://www.windmill.dev/) — the open-source developer platform for building internal tools, APIs, background jobs, workflows, and UIs.

Windmill turns scripts into shareable UIs automatically and lets you compose them into flows or build richer apps with low-code. It supports Python, TypeScript, Go, Bash, SQL, and GraphQL.

## Getting Started

### Build & Install

```sh
cloudron build
cloudron install -l windmill
```

> **Do NOT pass `--no-sso`** unless you specifically want to disable Cloudron SSO. The default install provisions OIDC automatically — no manual configuration needed.

### First Login

- **Default superadmin credentials:**
  - Username: `admin@windmill.dev`
  - Password: `changeme`

⚠️ **Change these credentials immediately after first login.**

Even with SSO enabled, use these credentials for the initial login to complete the setup wizard (create a new superadmin account and your first workspace). After that, use the **Cloudron** SSO button on the login page.

### Initial Setup

1. **Create your workspace** — the setup wizard walks you through this
2. **Add users** — Cloudron SSO is automatic; users can also be invited manually
3. **Start building** — create your first script or import from [Windmill Hub](https://hub.windmill.dev)

## Architecture

This package runs Windmill as a single container with 6 supervised processes:

| Process | Role |
|---|---|
| **PostgreSQL 16** | Embedded database (required — see [TECHNICAL.md](TECHNICAL.md) for why) |
| **Caddy** | Reverse proxy — routes `/ws/*` to LSP, everything else to windmill-server |
| **windmill-server** | API server and frontend (port 8001 internally) |
| **windmill-worker** | Script execution (default worker group) |
| **windmill-worker-native** | Lightweight jobs — REST, SQL, etc. (native group, 8 workers) |
| **credential-inject** | One-shot — injects OIDC and SMTP credentials into the database on boot |

**LSP** (code intelligence for the editor) runs as a separate Docker sidecar container, managed via Cloudron's `docker` addon.

### What's Included

- **Automatic Cloudron SSO** — OIDC credentials are injected on every boot; the "Cloudron" login button appears automatically
- **Automatic email** — Cloudron's SMTP infrastructure is configured on every boot; email notifications work out of the box
- **No artificial limits** — workspace, group, and SSO user caps are removed via patches
- **Full OAuth login flow** — restored from the open-source `windmill-oauth` crate
- **Audit logging** — restored for compliance and debugging
- **User management** — setup wizard, password management, and workspace auto-invite all work

### Runtime Support

| Runtime | Version |
|---|---|
| Python | 3.12 (primary), 3.11 |
| Node.js | 20 |
| Deno | 2.2 |
| Bun | 1.3 |
| Go | 1.26 |
| PHP | 8.3 |
| Docker CLI | Available for containerized jobs |

Package management: `uv` (Python), `npm` (Node.js), `composer` (PHP).

### Resource Requirements

- **Minimum:** 2 GB RAM, 2 CPU cores
- **Recommended:** 4 GB RAM, 4 CPU cores
- **Memory limit:** 4 GB (set in `CloudronManifest.json`)
- **Storage:** grows with scripts, flows, job logs, and the embedded database

## What's Patched

This package applies 8 patches to the Windmill OSS source to restore functionality that was moved behind the Enterprise Edition paywall in June 2025:

| Patch | What it does |
|---|---|
| `001-remove-limits` | Removes workspace (2) and group (3) caps |
| `002-restore-oauth` | Restores OAuth login flow; removes SSO user limit (10) |
| `003-restore-audit-logs` | Restores audit log recording and querying |
| `004-implement-email` | Implements email sending via SMTP |
| `005-remove-sso-limit-banner` | Removes misleading "Limited to 10 SSO users" frontend banner |
| `006-fix-openrouter-default-model` | Fixes default AI model for OpenRouter |
| `007-implement-user-mgmt` | Restores user creation, password hashing, setup wizard |
| `008-implement-workspace-auto-invite` | Restores workspace auto-invite settings |

See [`patches/README.md`](patches/README.md) for detailed descriptions of each patch, and [`TECHNICAL.md`](TECHNICAL.md) for the full patching strategy and rules for writing new patches.

## Updating Windmill

See the [How to Update Windmill](TECHNICAL.md#how-to-update-windmill) section in `TECHNICAL.md` for the full procedure. The short version:

1. Update the windmill submodule to the new tag
2. Re-apply and fix patches
3. Update `upstreamVersion` in `CloudronManifest.json`
4. `cloudron build && cloudron update`

## Backup & Data

All Windmill data lives under `/app/data/`:

- **`/app/data/postgresql/`** — the embedded PostgreSQL database (scripts, flows, schedules, job history, settings)
- **`/app/data/lsp_cache/`** — LSP cache for code intelligence

Cloudron's backup system captures everything under `/app/data/` automatically.

## Known Limitations

- **No nsjail sandbox** — Cloudron provides container-level isolation instead
- **Single-instance only** — no HA or multi-node workers
- **No multiplayer editing** (Enterprise Edition only)
- **No Git sync, SAML SSO, S3 helpers, external triggers, or OpenTelemetry** (Enterprise Edition)

See [Known Limitations](TECHNICAL.md#known-limitations) in `TECHNICAL.md` for the complete list.

## License

- **Windmill:** [AGPLv3](https://github.com/windmill-labs/windmill/blob/main/LICENSE) (Community Edition)
- **This Cloudron package:** [MIT](LICENSE)

## Contributing

This is an unofficial package. For issues specific to the Cloudron packaging, please open an issue in this repository. For Windmill core issues, use the [official Windmill repository](https://github.com/windmill-labs/windmill).