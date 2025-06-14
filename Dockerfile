FROM cloudron/base:4.2.0

ENV DEBIAN_FRONTEND=noninteractive

# Install dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        supervisor \
        gosu \
        curl \
        ca-certificates \
        wget \
        postgresql-client \
    && rm -rf /var/lib/apt/lists/*

# Install Caddy (official apt repository method)
RUN apt-get update && \
    apt-get install -y debian-keyring debian-archive-keyring apt-transport-https && \
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg && \
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list && \
    apt-get update && \
    apt-get install -y caddy

# Create necessary directories
RUN mkdir -p /app/code /app/data /run/windmill /tmp/data

# Copy application files (to be created)
COPY start.sh /app/code/start.sh
COPY supervisord.conf /etc/supervisor/conf.d/windmill.conf
COPY Caddyfile /app/code/Caddyfile

# TODO: Add Windmill server, worker, and LSP binaries to /app/code/windmill/
# e.g., COPY windmill/ /app/code/windmill/

# Set permissions
RUN chmod +x /app/code/start.sh && \
    chown -R cloudron:cloudron /app/data /run/windmill /tmp/data

# Set entrypoint
CMD ["/app/code/start.sh"]
