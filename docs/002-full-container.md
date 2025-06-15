# Plan: Building a Full Windmill Container for Cloudron (LSP as Sidecar via Docker Addon)

This document outlines the upgraded plan to create a comprehensive Docker image for Windmill on Cloudron, incorporating all essential components identified in the Windmill `docker-compose.yml` (excluding Enterprise-only features by default), and running the LSP as a separate container via the Cloudron `docker` addon.

## 1. Introduction

The goal is to build a single Docker image based on `cloudron/base:4.2.0` that includes:
- Windmill Server
- Windmill Default Worker
- Windmill Native Worker
- (Optionally, if feasible and FOSS) Windmill Indexer
- Necessary runtime dependencies for script execution (Python, Node.js, Deno)
- All managed by `supervisord`
- **Windmill LSP (Language Server Protocol) will run as a separate container, managed by the main app using the Cloudron `docker` addon**

## 2. LSP as a Sidecar Container

- The main Windmill app will use the Cloudron `docker` addon to launch and manage the official LSP container (`ghcr.io/windmill-labs/windmill-lsp:latest`).
- The main app will install `docker-ce-cli` and use `CLOUDRON_DOCKER_HOST` to communicate with the Docker API.
- The LSP container will be started (if not already running) by `start.sh` at app startup.
- The LSP container will be attached to the same Docker network as the main app, and Caddy will proxy `/ws/*` traffic to it.
- Persistent cache for the LSP will be provided by mounting `/app/data/lsp_cache` from the main app into the LSP container at `/pyls/.cache` or `/root/.cache`.

## 3. Dockerfile Enhancements

1.  **Base Image & Initial Setup:**
    ```dockerfile
    FROM cloudron/base:4.2.0
    ENV DEBIAN_FRONTEND=noninteractive
    ```

2.  **Install Base Dependencies & Caddy:**
    ```dockerfile
    RUN apt-get update && \
        apt-get install -y --no-install-recommends \
            supervisor gosu curl ca-certificates wget postgresql-client gnupg apt-transport-https \
        && rm -rf /var/lib/apt/lists/*
    # Install Caddy (official apt repository method)
    RUN apt-get update && \
        apt-get install -y debian-keyring debian-archive-keyring && \
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg && \
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list && \
        apt-get update && \
        apt-get install -y caddy
    ```

3.  **Install Scripting Runtimes & Docker CLI:**
    - Node.js (LTS), Python (3.11), Deno for Windmill workers.
    - Docker CLI for LSP and worker container management.
    ```dockerfile
    RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
        apt-get install -y nodejs
    RUN apt-get install -y python3.11 python3-pip python3.11-venv
    RUN update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.11 1
    RUN update-alternatives --install /usr/bin/pip3 pip3 /usr/bin/pip3 1
    RUN curl -fsSL https://deno.land/x/install/install.sh | sh && \
        cp /root/.deno/bin/deno /usr/local/bin/
    RUN apt-get update && apt-get install -y docker-ce-cli
    ```

4.  **Create Directories:**
    ```dockerfile
    RUN mkdir -p /app/code/windmill /app/data /run/windmill /tmp/data /app/data/lsp_cache /app/data/windmill_index
    ```

5.  **Acquire Windmill Core Binary:**
    ```dockerfile
    ARG WINDMILL_VERSION=v1.496.3
    ARG WINDMILL_ARCH=amd64
    RUN curl -L -o /app/code/windmill/windmill "https://github.com/windmill-labs/windmill/releases/download/${WINDMILL_VERSION}/windmill-${WINDMILL_ARCH}" && \
        chmod +x /app/code/windmill/windmill
    ```

6.  **Copy Configuration Files:**
    ```dockerfile
    COPY start.sh /app/code/start.sh
    COPY supervisord.conf /etc/supervisor/conf.d/windmill.conf
    COPY Caddyfile /app/code/Caddyfile
    ```

7.  **Set Permissions & Entrypoint:**
    ```dockerfile
    RUN chmod +x /app/code/start.sh && \
        chown -R cloudron:cloudron /app/data /run/windmill /tmp /app/code/windmill
    CMD ["/app/code/start.sh"]
    ```

## 4. Updating `start.sh`

- At startup, `start.sh` will:
    1. Ensure `/app/data/lsp_cache` exists and is owned by `cloudron`.
    2. Use `docker --host "$CLOUDRON_DOCKER_HOST"` to check if the LSP container is running.
    3. If not running, pull the latest LSP image and run it with:
        - Name: `windmill-lsp-service`
        - Network: same as main app (Cloudron's internal Docker network)
        - Port: expose 3001 inside the LSP container
        - Mount `/app/data/lsp_cache` to `/pyls/.cache` (or `/root/.cache` as needed)
        - Set `XDG_CACHE_HOME` in the LSP container
        - Restart policy: always
    4. Set `LSP_SERVER_INTERNAL_ADDR=windmill-lsp-service:3001` for Caddy to proxy to the LSP container.

## 5. Updating `supervisord.conf`

- Remove `[program:windmill-lsp]` (LSP is no longer managed by supervisord).
- Optionally, add a `[program:lsp-manager]` to ensure the LSP container is running, or rely on `start.sh` to launch it at startup.

## 6. Updating `Caddyfile`

- The `reverse_proxy /ws/* {$LSP_SERVER_INTERNAL_ADDR}` directive will now point to `windmill-lsp-service:3001` (the LSP container's Docker network name and port).

## 7. Updating `CloudronManifest.json`

- Add `"docker": {}` to the `addons` section.
- Increase `memoryLimit` as needed for the main app and LSP container.
- Document that the app requires superadmin privileges to install due to the `docker` addon.

## 8. Worker Docker Integration

- Windmill workers that need to spawn containers will use the `CLOUDRON_DOCKER_HOST` environment variable and the installed Docker CLI.
- The app will not mount `/var/run/docker.sock` but will use the Cloudron-provided Docker API endpoint.

## 9. Next Steps & Testing

1. Implement the Dockerfile changes, focusing on binary acquisition and runtime installations.
2. Update `start.sh` to manage the LSP container.
3. Update `supervisord.conf` to remove LSP and optionally add a manager.
4. Update `Caddyfile` to proxy to the LSP container.
5. Update `CloudronManifest.json` for the `docker` addon and memory.
6. Build and test the image on Cloudron, ensuring:
    - Server UI access
    - OIDC login
    - Script execution in workers
    - LSP functionality in the editor
    - Log output via `cloudron logs`
    - Docker integration for workers and LSP
    - Email trigger functionality (if implemented)

This approach leverages Cloudron's `docker` addon for both LSP and worker containerization, keeping the main image focused and maintainable.
