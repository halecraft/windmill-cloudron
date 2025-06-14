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

# Install Caddy (official instructions)
RUN wget -O - https://caddyserver.com/api/download?os=linux\&arch=amd64\&p=github.com%2Fcaddyserver%2Fcaddy | tar -xz -C /usr/bin caddy && \
    chmod +x /usr/bin/caddy

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
