FROM cloudron/base:4.2.0

ENV DEBIAN_FRONTEND=noninteractive

# Install base dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        supervisor \
        gosu \
        curl \
        ca-certificates \
        wget \
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
RUN mkdir -p /app/code/windmill /app/data /run/windmill /tmp/data /app/data/lsp_cache /app/data/windmill_index

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

# Set permissions
RUN chmod +x /app/code/start.sh && \
    chown -R cloudron:cloudron /app/data /run/windmill /tmp /app/code/windmill

# Set entrypoint
CMD ["/app/code/start.sh"]
