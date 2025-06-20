# Windmill for Cloudron

An **unofficial** Cloudron package for [Windmill](https://www.windmill.dev/) - the open-source developer platform for building internal tools, APIs, background jobs, workflows and UIs.

Windmill turns scripts into shareable UIs automatically and allows you to compose them into flows or build richer apps with low-code. It supports Python, TypeScript, Go, Bash, SQL, and GraphQL scripts.

## 🚀 Getting Started

### Installation

Use the `cloudron` CLI to install, e.g.
  - `cloudron build`, then
  - `cloudron install --image docker.yourregistry.com/windmill -l windmill`

### First Login

After installation, access your Windmill instance at your configured domain:

- **Default superadmin credentials**:
  - Username: `admin@windmill.dev`
  - Password: `changeme`

⚠️ **Important**: Change these credentials immediately after first login!

### Initial Setup

1. **Create your workspace**: Follow the setup wizard to create your first workspace
2. **Add users**: Invite team members or configure SSO (see technical details below)
3. **Start building**: Create your first script or import from [Windmill Hub](https://hub.windmill.dev)

### Quick Start Example

1. Go to **Scripts** → **+ New Script**
2. Choose **Python** or **TypeScript**
3. Write a simple script:
   ```python
   def main(name: str = "World"):
       return f"Hello {name}!"
   ```
4. Click **Save & Run** - Windmill automatically generates a UI for your script!

## 🔧 Technical Details for Cloudron Admins

### Architecture

This Cloudron package includes:
- **Windmill server** and **worker** processes managed by supervisord
- **PostgreSQL** database (self-managed, not using Cloudron's PostgreSQL addon due to Cloudron limitations)
- **Caddy** reverse proxy for internal routing
- **LSP container** for code intelligence (Python, TypeScript, etc.)

### Resource Requirements

- **Minimum**: 2GB RAM, 2 CPU cores
- **Recommended**: 4GB RAM, 4 CPU cores
- **Storage**: Grows with your scripts, flows, and job logs

### Security & Isolation

- Scripts run in **sandboxed environments** using nsjail
- **Docker addon** is required for worker containerization and LSP services
- All secrets and credentials are **encrypted** in the database
- **OIDC/SSO** support available through Cloudron's OIDC addon

### Backup Considerations

Your Windmill data includes:
- **Database**: All scripts, flows, schedules, and job history
- **Local storage**: File uploads, custom certificates, cache data

Regular Cloudron backups will capture both the database and local storage.

### Environment & Runtime Support

This package includes pre-installed runtimes for:
- **Python 3.11** with `uv` package manager
- **Node.js 20** and **npm**
- **Deno** runtime
- **Go** compiler
- **Docker CLI** for containerized jobs

### Networking

- **HTTP Port**: 8000 (automatically configured by Cloudron)
- **Internal services**: Caddy proxy, PostgreSQL, LSP container
- **External access**: Only through Cloudron's reverse proxy

### Monitoring & Logs

- **Application logs**: Available through Cloudron's log viewer
- **Job execution logs**: Visible within Windmill's web interface
- **Health checks**: Automatic health monitoring via Cloudron

### Scaling Considerations

- **Single-instance**: This package runs all components in one container
- **Worker scaling**: Additional workers can be configured through Windmill's settings
- **Database**: PostgreSQL runs locally; for high-load scenarios, consider external database

## 📝 License & Support

- **Windmill**: AGPLv3 (Community Edition)
- **This Cloudron package**: MIT

## 🤝 Contributing

This is an unofficial package. For issues specific to the Cloudron packaging, please check the package repository. For Windmill core issues, use the [official Windmill repository](https://github.com/windmill-labs/windmill).

