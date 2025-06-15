# Plan: Packaging Windmill for Cloudron

This document outlines the plan to package Windmill, an open-source developer platform, for Cloudron. The goal is to create a custom Docker container based on the `cloudron/base:4.2.0` image that supports all necessary Windmill components.

## 1. Understanding Windmill Architecture for Cloudron

Windmill consists of several key components. For Cloudron, we will integrate these into a single Docker image, leveraging Cloudron addons where appropriate.

*   **Core Components to be run by Supervisor:**
    *   **Windmill Server:** Serves the frontend UI and API. Will be configured to listen on an internal port (e.g., `8001`).
    *   **Windmill Worker:** Executes jobs and flows. Multiple worker processes might be run, configurable via an environment variable.
*   **Supporting Services (to be included in the container and run by Supervisor):**
    *   **Windmill LSP (Language Server Protocol):** Provides editor intellisense. Will be configured to listen on an internal port (e.g., `3002`).
    *   **Internal Reverse Proxy (Caddy):** To manage internal routing from a single `httpPort` (defined in `CloudronManifest.json`, e.g., `8000`) to the Windmill server and LSP service.
*   **Cloudron Addons to be Utilized:**
    *   **PostgreSQL Database:** Provided by the Cloudron `postgresql` addon. Windmill's entire state resides here.
    *   **Local Storage:** Provided by the Cloudron `localstorage` addon for `/app/data`, used for initialization flags, persistent configurations not suitable for env vars, and custom CA certificates.
    *   **OIDC:** For single sign-on integration with Cloudron's authentication system.
*   **Direct Port Exposure (via Cloudron Manifest):**
    *   **Email Triggers:** Windmill server will listen directly on a TCP port (e.g., `2525`) for email triggers. This port will be mapped via `tcpPorts` in `CloudronManifest.json`.
*   **Out of Scope (for initial FOSS package):**
    *   **Windmill Multiplayer:** This is an Enterprise feature and will not be included in the initial open-source package.

## 2. Core Files to Create

Following Cloudron best practices, we will create:

*   `CloudronManifest.json`: Defines app metadata, addons, ports, health checks, and OIDC configuration.
*   `Dockerfile`: Builds the Windmill application image.
*   `start.sh`: Entrypoint script for initializing the environment, database, configurations, and starting services.
*   `supervisord.conf`: Configuration file for `supervisord` to manage Windmill server, worker(s), LSP, and Caddy processes.
*   `Caddyfile`: Configuration for the internal Caddy reverse proxy.
*   `DESCRIPTION.md`: A brief description of the application for the manifest.
*   `icon.png`: Application icon.

## 3. Dockerfile Construction (`Dockerfile`)

The `Dockerfile` will perform the following steps:

1.  **Base Image:** Start from `cloudron/base:4.2.0`.
2.  **Environment Variables:** Set `DEBIAN_FRONTEND=noninteractive`.
3.  **Install Dependencies:**
    *   Update package lists (`apt-get update`).
    *   Install `supervisor`, `curl`, `gosu`, `ca-certificates`, `gnupg`, `wget`, `postgresql-client` (for `psql`).
    *   Install Caddy (following official instructions for Debian/Ubuntu, ensuring it can be run by a non-root user if possible, or manage permissions accordingly).
4.  **Fetch Windmill Artifacts:**
    *   Determine the best way to get Windmill server, worker, and LSP binaries/executables. This might involve:
        *   Downloading pre-compiled binaries if available.
        *   Using a multi-stage build to extract them from Windmill's official Docker images (`windmill-labs/windmill`, `windmill-labs/windmill-lsp`).
    *   Place these artifacts into `/app/code/windmill/`.
5.  **Copy Application Files:**
    *   Copy `start.sh` to `/app/code/start.sh` and make it executable (`chmod +x`).
    *   Copy `supervisord.conf` to `/etc/supervisor/conf.d/windmill.conf`.
    *   Copy the custom `Caddyfile` to `/app/code/Caddyfile`.
6.  **Setup Directories:**
    *   Create `/app/data` (Cloudron mounts this).
    *   Create `/run/windmill` for runtime files (e.g., supervisor socket, PIDs).
    *   Create `/tmp/data` for any initial data to be copied to `/app/data` on first run (if any).
7.  **Entrypoint:** Set `CMD ["/app/code/start.sh"]`.

## 4. Startup Script (`start.sh`)

The `start.sh` script will be responsible for:

1.  **Environment Setup:**
    *   Source any necessary environment files or set defaults.
    *   Define internal ports and addresses for Windmill services (e.g., `WINDMILL_SERVER_INTERNAL_ADDR=127.0.0.1:8001`, `LSP_SERVER_INTERNAL_ADDR=127.0.0.1:3002`).
    *   Set `INTERNAL_CADDY_HTTP_LISTEN_PORT=${CLOUDRON_HTTP_PORT}` for Caddy.
2.  **Wait for PostgreSQL:** Implement a loop to wait until the PostgreSQL service provided by Cloudron is available.
3.  **Initialize `/app/data` (First Run Only):**
    *   Check for an initialization marker (e.g., `/app/data/.initialized_windmill`).
    *   If not present:
        *   Copy any default configurations from `/tmp/data` to `/app/data`.
        *   Perform database initialization for Windmill:
            *   Connect to PostgreSQL using `psql -v ON_ERROR_STOP=1 --username "$CLOUDRON_POSTGRESQL_USERNAME" --host "$CLOUDRON_POSTGRESQL_HOST" --port "$CLOUDRON_POSTGRESQL_PORT" -d "$CLOUDRON_POSTGRESQL_DATABASE"`.
            *   Execute SQL commands adapted from Windmill's `init-db-as-superuser.sql` to create `windmill_admin` and `windmill_user` roles.
            *   Grant these roles to `$CLOUDRON_POSTGRESQL_USERNAME`.
            *   Example SQL:
                ```sql
                CREATE ROLE windmill_admin NOLOGIN;
                CREATE ROLE windmill_user NOLOGIN;
                -- Add other non-superuser DDL from Windmill's script if necessary
                GRANT windmill_admin TO "${CLOUDRON_POSTGRESQL_USERNAME}";
                GRANT windmill_user TO "${CLOUDRON_POSTGRESQL_USERNAME}";
                ```
        *   Create the `.initialized_windmill` marker file.
4.  **Handle Custom CA Certificates:**
    *   If a directory `/app/data/ca-certs/` exists and contains `.crt` files:
        *   Copy certificates to `/usr/local/share/ca-certificates/`.
        *   Run `update-ca-certificates`.
    *   Set `DENO_TLS_CA_STORE=system,mozilla`, `REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt`, `SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt` as environment variables for Windmill processes if custom CAs are used.
5.  **Set Permissions:**
    *   `chown -R cloudron:cloudron /app/data`
    *   `chown -R cloudron:cloudron /run/windmill`
    *   `chown -R cloudron:cloudron /tmp` (if necessary)
6.  **Launch Services:**
    *   Start `supervisord` in the foreground: `exec /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf`.

## 5. Process Management (`supervisord.conf`)

Configure `supervisord` to manage the following processes, all running as the `cloudron` user via `gosu cloudron:cloudron`:

1.  **Caddy Process:**
    *   Command: `gosu cloudron:cloudron caddy run --config /app/code/Caddyfile --adapter caddyfile`
    *   Environment: Pass `INTERNAL_CADDY_HTTP_LISTEN_PORT`, `WINDMILL_SERVER_INTERNAL_ADDR`, `LSP_SERVER_INTERNAL_ADDR`.
    *   Logging: `stdout`/`stderr`.
2.  **Windmill Server Process:**
    *   Command: `gosu cloudron:cloudron /app/code/windmill/windmill server --db-url="${CLOUDRON_POSTGRESQL_URL}" --base-url="${CLOUDRON_APP_ORIGIN}" --port="8001" --worker-instance-id="server0" ... (other necessary flags)`
    *   Environment: Pass relevant `CLOUDRON_*` variables, `DATABASE_URL=${CLOUDRON_POSTGRESQL_URL}`, `BASE_URL=${CLOUDRON_APP_ORIGIN}`.
    *   Logging: `stdout`/`stderr`.
3.  **Windmill Worker Process(es):**
    *   Command: `gosu cloudron:cloudron /app/code/windmill/windmill worker --db-url="${CLOUDRON_POSTGRESQL_URL}" ... (other necessary flags)`
    *   Environment: Pass `DATABASE_URL=${CLOUDRON_POSTGRESQL_URL}`.
    *   `numprocs`: Potentially configurable via an env var (e.g., `WINDMILL_NUM_WORKERS`, default 1 or 2).
    *   Logging: `stdout`/`stderr`.
4.  **Windmill LSP Process:**
    *   Command: `gosu cloudron:cloudron /app/code/windmill/windmill-lsp --port="3002" ... (other necessary flags)`
    *   Environment: Pass necessary env vars.
    *   Logging: `stdout`/`stderr`.

## 6. Internal Reverse Proxy (`Caddyfile`)

The `Caddyfile` for the internal Caddy instance:

```caddy
{
    # Caddy global options
    # e.g., admin off
    # log stdout format console # Handled per-site block
}

# INTERNAL_CADDY_HTTP_LISTEN_PORT will be set to CLOUDRON_HTTP_PORT by start.sh
# WINDMILL_SERVER_INTERNAL_ADDR will be e.g. 127.0.0.1:8001
# LSP_SERVER_INTERNAL_ADDR will be e.g. 120.0.0.1:3002

http://:{$INTERNAL_CADDY_HTTP_LISTEN_PORT} {
    log {
        output stdout
        format console
    }

    # Route LSP WebSocket and other /ws/ traffic
    reverse_proxy /ws/* {$LSP_SERVER_INTERNAL_ADDR} {
        # Potentially add headers for WebSocket if needed
        # header_up X-Forwarded-Proto {scheme}
    }

    # Route all other traffic to the Windmill server
    reverse_proxy /* {$WINDMILL_SERVER_INTERNAL_ADDR}
}
```

## 7. Cloudron Manifest (`CloudronManifest.json`)

Key fields for `CloudronManifest.json`:

```json
{
  "id": "com.windmill-labs.cloudronapp", // Or a custom domain based one
  "title": "Windmill",
  "author": "Your Name/Org <contact@example.com>",
  "version": "1.0.0-cloudron1", // WindmillVersion-CloudronPackageVersion
  "description": "file://DESCRIPTION.md",
  "tagline": "Open-source developer platform to build production-grade workflows and UIs from scripts.",
  "healthCheckPath": "/", // Or a specific health endpoint if Windmill provides one
  "httpPort": 8000, // Port Caddy listens on, Cloudron proxy forwards to this
  "tcpPorts": {
    "EMAIL_TRIGGER": {
      "title": "Email Trigger Port",
      "description": "Port for Windmill email triggers",
      "containerPort": 2525, // Port Windmill server directly listens on
      "externalPort": 25 // Default, can be changed by user during install
    }
  },
  "addons": {
    "postgresql": {},
    "localstorage": {},
    "oidc": {
      "loginRedirectUri": "/oauth/callback", // Needs verification for Windmill's exact OIDC callback path
      "scopes": "openid profile email",
      "discoveryUrl": "{{CLOUDRON_OIDC_DISCOVERY_URL}}", // Standard practice
      "clientId": "{{CLOUDRON_OIDC_CLIENT_ID}}",
      "clientSecret": "{{CLOUDRON_OIDC_CLIENT_SECRET}}"
    }
  },
  "manifestVersion": 2,
  "website": "https://www.windmill.dev/",
  "contactEmail": "contact@windmill.dev", // Or packager's email
  "icon": "file://icon.png", // Provide a 128x128 or 256x256 PNG
  "tags": ["developer tools", "automation", "workflow"],
  "memoryLimit": 2147483648, // 2GB, adjust as needed
  "minBoxVersion": "7.4.0", // Check current recommended minBoxVersion
  "postInstallMessage": "Windmill has been installed!\n\nDefault superadmin credentials (use these for the first login, even if SSO is configured):\n*   **Username:** `admin@windmill.dev`\n*   **Password:** `changeme`\n\nAccess Windmill at [$CLOUDRON_APP_ORIGIN]($CLOUDRON_APP_ORIGIN).\n\nAfter the first login, you will be prompted to create a new superadmin account and workspace. You can then configure OIDC for SSO if desired under instance settings."
}
```

## 8. Configuration Management

*   Windmill configurations (like `DATABASE_URL`, `BASE_URL`, OIDC settings) will be primarily managed via environment variables passed by Cloudron and `start.sh`.
*   The default `.env` file mechanism of Windmill will be bypassed or adapted to use these environment variables.
*   User-configurable settings beyond what Cloudron addons provide (e.g., specific Windmill features, number of workers) can be exposed as environment variables in the `CloudronManifest.json` if necessary, or users can set them via `cloudron env set`.

## 9. Testing and Iteration Strategy

1.  **Local Build:** `docker build -t myusername/windmill-cloudron .`
2.  **Push to Registry:** Push the image to a Docker registry accessible by the Cloudron instance.
3.  **Cloudron Install:** `cloudron install --image myusername/windmill-cloudron:latest`
4.  **Functional Testing:**
    *   Verify first login with default credentials.
    *   Test OIDC login if configured.
    *   Create a workspace.
    *   Test basic script/flow execution (Python, TypeScript, Bash).
    *   Verify LSP functionality in the editor.
    *   Test email trigger functionality if possible.
5.  **Log Inspection:** `cloudron logs -f --app <app_location>` for debugging.
6.  **Iterate:** Refine `Dockerfile`, `start.sh`, `supervisord.conf`, `Caddyfile`, and `CloudronManifest.json` based on testing results.
7.  **Update Testing:** Test the update process: `cloudron update --app <app_location> --image myusername/windmill-cloudron:newtag`.

This plan provides a structured approach to packaging Windmill for Cloudron. Each step will require careful implementation and testing.
