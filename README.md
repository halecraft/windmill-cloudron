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
- **No artificial limits** — workspace, group, and SSO user caps are removed
- **Full OAuth login flow** — restored from the open-source `windmill-oauth` crate in our fork
- **S3/object storage** — workspace file browser, file upload/download, and job S3 access restored
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

## What's Modified

This package maintains a [fork of Windmill](https://github.com/halecraft/windmill) with modifications to restore functionality moved behind the Enterprise Edition paywall in June 2025. Changes are managed as a stack of [jj](https://jj-vcs.github.io/jj/) changes on a `cloudron` bookmark:

| Modification | What it does |
|---|---|
| Restore audit logs | Audit log recording, querying, and listing |
| Implement email | SMTP email sending via the `mail-send` crate |
| Implement user management | User creation, password hashing, setup wizard |
| Workspace auto-invite | Workspace auto-invite settings endpoint |
| Restore OAuth + fix OpenRouter | Full OAuth login flow; fixes default AI model |
| Remove limits + banners | Removes workspace (2), group (3), SSO user (10) caps and frontend banner |
| Version string | Honest `X.Y.Z-cloudron` version instead of upstream git tag |
| S3 object storage | Workspace file browser, multipart upload, job S3 access |

See [`TECHNICAL.md`](TECHNICAL.md) for the full fork architecture and modification rules.

## Updating Windmill

See [How to Update Windmill](TECHNICAL.md#9-how-to-update-windmill) in `TECHNICAL.md`. The short version:

1. Fetch upstream: `cd windmill && jj git fetch --remote upstream`
2. Rebase: `jj rebase -b cloudron -d v<new_version>`
3. Resolve conflicts, update `CloudronManifest.json`
4. `cloudron build && cloudron update`

The version string (`X.Y.Z-cloudron`) updates automatically on rebase.

## Backup & Data

All Windmill data lives under `/app/data/`:

- **`/app/data/postgresql/`** — the embedded PostgreSQL database (scripts, flows, schedules, job history, settings)
- **`/app/data/lsp_cache/`** — LSP cache for code intelligence

Cloudron's backup system captures everything under `/app/data/` automatically.

## Known Limitations

- **No nsjail sandbox** — Cloudron provides container-level isolation instead
- **Single-instance only** — no HA or multi-node workers
- **No multiplayer editing** — requires a separate service not shipped in this build
- **No Git sync, SAML SSO, Kafka/NATS/SQS/GCP/Azure triggers, or OpenTelemetry** — not enabled in this build

This Cloudron package neutralizes EE/license gating: working features previously gated behind a license check (schedule recovery hooks, mute error handler, restart flow from step, admins-workspace member adds, folder admin ops) are enabled, and service accounts, critical alerts (low-disk, jobs-waiting), and the AI documentation assistant (embedded `llms.txt` corpus) are implemented in the OSS fork. BigQuery, MSSQL, and OracleDB script executors are unlocked.

See [Known Limitations](TECHNICAL.md#known-limitations) in `TECHNICAL.md` for the complete list.

## License

- **Windmill:** [AGPLv3](https://github.com/windmill-labs/windmill/blob/main/LICENSE) (Community Edition)
- **This Cloudron package:** [MIT](LICENSE)

## Contributing

This is an unofficial package. For issues specific to the Cloudron packaging, please open an issue in this repository. For Windmill core issues, use the [official Windmill repository](https://github.com/windmill-labs/windmill).