FROM cloudron/base:4.2.0

ENV DEBIAN_FRONTEND=noninteractive
ENV UV_PYTHON_INSTALL_DIR=/tmp/windmill/cache/py_runtime
ENV UV_PYTHON_PREFERENCE=only-managed
ENV UV_TOOL_BIN_DIR=/usr/local/bin

# Install base dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        supervisor \
        gosu \
        curl \
        ca-certificates \
        wget \
        postgresql \
        postgresql-contrib \
        postgresql-client \
        gnupg \
        apt-transport-https \
    && rm -rf /var/lib/apt/lists/*

# Install Caddy (official apt repository method)
RUN apt-get update && \
    apt-get install -y debian-keyring debian-archive-keyring && \
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg && \
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list && \
    apt-get update && \
    apt-get install -y caddy

# Install Node.js (LTS), Python 3.11, Deno, and Docker CLI
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
    apt-get install -y nodejs
RUN apt-get install -y python3.11 python3-pip python3.11-venv
RUN update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.11 1

# Install uv (matching the method in upstream Windmill Dockerfile)
RUN curl --proto '=https' --tlsv1.2 -LsSf https://github.com/astral-sh/uv/releases/download/0.6.2/uv-installer.sh | sh && \
    mv /root/.local/bin/uv /usr/local/bin/uv && \
    chmod +x /usr/local/bin/uv

RUN curl -fsSL https://deno.land/x/install/install.sh | sh && \
    cp /root/.deno/bin/deno /usr/local/bin/
# Install Docker CLI (docker-ce-cli)
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg \
        lsb-release
RUN mkdir -p /etc/apt/keyrings && \
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
RUN export ARCH=$(dpkg --print-architecture) && \
    echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
    $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
RUN apt-get update && apt-get install -y docker-ce-cli

# Create necessary directories
RUN mkdir -p /app/code/windmill /app/data /run/windmill /tmp/data /app/data/lsp_cache /app/data/windmill_index /app/data/postgresql /tmp/windmill/cache/py_runtime

# Acquire Windmill core binary
ARG WINDMILL_VERSION=v1.496.3
ARG WINDMILL_ARCH=amd64
RUN ARCH="${WINDMILL_ARCH:-$(dpkg --print-architecture)}" && \
    echo "Downloading Windmill binary for arch: $ARCH" && \
    curl -L -o /app/code/windmill/windmill "https://github.com/windmill-labs/windmill/releases/download/${WINDMILL_VERSION}/windmill-${ARCH}" && \
    chmod +x /app/code/windmill/windmill

# Copy application files
COPY start.sh /app/code/start.sh
COPY supervisord.conf /etc/supervisor/conf.d/windmill.conf
COPY Caddyfile /app/code/Caddyfile
COPY windmill/init-db-as-superuser.sql /app/code/init-db-as-superuser.sql

# Set permissions
RUN chmod +x /app/code/start.sh && \
    chown -R cloudron:cloudron /app/data /run/windmill /tmp /app/code/windmill && \
    chown -R postgres:postgres /app/data/postgresql

# Set entrypoint
CMD ["/app/code/start.sh"]
