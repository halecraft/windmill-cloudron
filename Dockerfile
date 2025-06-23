# ARG DEBIAN_IMAGE=debian:bookworm-slim
ARG DEBIAN_IMAGE=cloudron/base:4.2.0
ARG RUST_IMAGE=rust:1.86-slim-bookworm

FROM --platform=linux/amd64 ${RUST_IMAGE} AS rust_base
  RUN apt-get update && apt-get install -y git libssl-dev pkg-config npm
  
  RUN apt-get -y update \
      && apt-get install -y \
      curl nodejs
  
  RUN rustup component add rustfmt
  
  RUN CARGO_NET_GIT_FETCH_WITH_CLI=true cargo install cargo-chef --version 0.1.68
  RUN cargo install sccache --version ^0.8
  ENV RUSTC_WRAPPER=sccache SCCACHE_DIR=/backend/sccache
  
  WORKDIR /windmill
  
  ENV SQLX_OFFLINE=true

FROM --platform=linux/amd64 node:20-alpine AS frontend
  ARG WINDMILL_SRC=./windmill
  # install dependencies
  WORKDIR /frontend
  COPY ${WINDMILL_SRC}/frontend/package.json ${WINDMILL_SRC}/frontend/package-lock.json ./
  COPY ${WINDMILL_SRC}/frontend/scripts/ ./scripts/
  RUN npm ci

  # Copy all local files into the image.
  COPY ${WINDMILL_SRC}/frontend .
  RUN mkdir /backend
  COPY ${WINDMILL_SRC}/backend/windmill-api/openapi.yaml /backend/windmill-api/openapi.yaml
  COPY ${WINDMILL_SRC}/openflow.openapi.yaml /openflow.openapi.yaml
  COPY ${WINDMILL_SRC}/backend/windmill-api/build_openapi.sh /backend/windmill-api/build_openapi.sh

  RUN cd /backend/windmill-api && . ./build_openapi.sh
  COPY ${WINDMILL_SRC}/backend/parsers/windmill-parser-wasm/pkg/ /backend/parsers/windmill-parser-wasm/pkg/
  COPY ${WINDMILL_SRC}/typescript-client/docs/ /frontend/static/tsdocs/

  RUN npm run generate-backend-client
  ENV NODE_OPTIONS="--max-old-space-size=8192"
  ARG VITE_BASE_URL ""
  # Read more about macro in docker/dev.nu
  # -- MACRO-SPREAD-WASM-PARSER-DEV-ONLY -- # 
  RUN npm run build


FROM --platform=linux/amd64 rust_base AS planner
  ARG WINDMILL_SRC=./windmill
  COPY ${WINDMILL_SRC}/openflow.openapi.yaml /openflow.openapi.yaml
  COPY ${WINDMILL_SRC}/backend ./
  
  RUN --mount=type=cache,target=/usr/local/cargo/registry \
      --mount=type=cache,target=$SCCACHE_DIR,sharing=locked \
      CARGO_NET_GIT_FETCH_WITH_CLI=true cargo chef prepare --recipe-path recipe.json
  

FROM --platform=linux/amd64 rust_base AS builder
  ARG WINDMILL_SRC=./windmill
  ARG features=""
  
  COPY --from=planner /windmill/recipe.json recipe.json
  
  RUN apt-get update && apt-get install -y libxml2-dev=2.9.* libxmlsec1-dev=1.2.* clang=1:14.0-55.* libclang-dev=1:14.0-55.* cmake=3.25.* && \
      apt-get clean && \
      rm -rf /var/lib/apt/lists/*
  
  RUN --mount=type=cache,target=/usr/local/cargo/registry \
      --mount=type=cache,target=$SCCACHE_DIR,sharing=locked \
      CARGO_NET_GIT_FETCH_WITH_CLI=true RUST_BACKTRACE=1 cargo chef cook --release --features "$features" --recipe-path recipe.json
  
  COPY ${WINDMILL_SRC}/openflow.openapi.yaml /openflow.openapi.yaml
  COPY ${WINDMILL_SRC}/backend ./
  
  RUN mkdir -p /frontend
  
  COPY --from=frontend /frontend/build /frontend/build
  COPY --from=frontend /backend/windmill-api/openapi-deref.yaml ./windmill-api/openapi-deref.yaml
  COPY .git/ .git/
  
  RUN --mount=type=cache,target=/usr/local/cargo/registry \
      --mount=type=cache,target=$SCCACHE_DIR,sharing=locked \
      CARGO_NET_GIT_FETCH_WITH_CLI=true cargo build --release --features "$features"


# Add a stage for the docker client
FROM --platform=linux/amd64 docker:dind AS docker_client

FROM ${DEBIAN_IMAGE}
  ARG TARGETPLATFORM
  ARG GO_VERSION=1.22.5
  ARG APP=/app/code
  ARG WINDMILL_SRC=./windmill
  
  # To change latest stable version:
  # 1. Change placeholder in instanceSettings.ts
  # 2. Change LATEST_STABLE_PY in dockerfile
  # 3. Change #[default] annotation for PyVersion in backend
  ARG LATEST_STABLE_PY=3.11.10
  ENV UV_PYTHON_INSTALL_DIR=/tmp/windmill/cache/py_runtime
  ENV UV_PYTHON_PREFERENCE=only-managed
  ENV UV_TOOL_BIN_DIR=/usr/local/bin
  
  ENV PATH=/usr/local/bin:/root/.local/bin:$PATH
  
  # Add Docker CLI debian source (docker-ce-cli)
  RUN apt-get update && \
      apt-get install -y --no-install-recommends \
          ca-certificates \
          curl \
          gnupg \
          lsb-release
  RUN mkdir -p /etc/apt/keyrings && \
      curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  RUN echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
  
  # Install base dependencies
  RUN apt-get update && \
      apt-get install -y --no-install-recommends \
          apt-transport-https \
          build-essential \
          ca-certificates \
          curl \
          docker-ce-cli \
          git \
          gnupg \
          gosu \
          jq \
          netbase \
          postgresql \
          postgresql-client \
          postgresql-contrib \
          software-properties-common \
          supervisor \
          tzdata \
          unixodbc \
          unzip \
          wget \
          xmlsec1 \
      && apt-get clean \
      && rm -rf /var/lib/apt/lists/*
      
  # Install Caddy (official apt repository method)
  RUN apt-get update && \
      apt-get install -y debian-keyring debian-archive-keyring && \
      curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg && \
      curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list && \
      apt-get update && \
      apt-get install -y caddy
  
  # Install go-lang
  RUN curl -fsSL https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz | tar -C /usr/local -xz

  ENV PATH="${PATH}:/usr/local/go/bin"
  ENV GO_PATH=/usr/local/go/bin/go
  
  # Install UV
  RUN curl --proto '=https' --tlsv1.2 -LsSf https://github.com/astral-sh/uv/releases/download/0.6.2/uv-installer.sh | sh && mv /root/.local/bin/uv /usr/local/bin/uv
  
  # Preinstall python runtimes
  RUN uv python install 3.11
  RUN uv python install $LATEST_STABLE_PY
  
  RUN uv venv
  
  # Install nodejs
  RUN curl -sL https://deb.nodesource.com/setup_20.x | bash - 
  RUN apt-get -y update && apt-get install -y curl procps nodejs awscli && apt-get clean \
      && rm -rf /var/lib/apt/lists/*
  
  # go build is slower the first time it is ran, so we prewarm it in the build
  RUN mkdir -p /tmp/gobuildwarm && cd /tmp/gobuildwarm && go mod init gobuildwarm && printf "package foo\nimport (\"fmt\")\nfunc main() { fmt.Println(42) }" > warm.go && go mod tidy && go build -x && rm -rf /tmp/gobuildwarm
  
  ENV TZ=Etc/UTC
  
  COPY --from=builder /frontend/build /static_frontend
  COPY --from=builder /windmill/target/release/windmill ${APP}/windmill
  
  COPY --from=denoland/deno:2.2.1 --chmod=755 /usr/bin/deno /usr/bin/deno
  
  COPY --from=oven/bun:1.2.4 /usr/local/bin/bun /usr/bin/bun
  
  COPY --from=php:8.3.7-cli /usr/local/bin/php /usr/bin/php
  COPY --from=composer:2.7.6 /usr/bin/composer /usr/bin/composer
  
  # add the docker client to call docker from a worker if enabled
  COPY --from=docker_client /usr/local/bin/docker /usr/local/bin/
  
  ENV RUSTUP_HOME="/usr/local/rustup"
  ENV CARGO_HOME="/usr/local/cargo"
  
  WORKDIR ${APP}
  
  RUN ln -s ${APP}/windmill /usr/local/bin/windmill
  
  COPY ${WINDMILL_SRC}/frontend/src/lib/hubPaths.json ${APP}/hubPaths.json
  
  RUN windmill cache ${APP}/hubPaths.json && rm ${APP}/hubPaths.json && chmod -R 777 /tmp/windmill
  
  # Create a non-root user 'windmill' with UID and GID 1000
  RUN addgroup windmill && \
      adduser --disabled-password --gecos "" --ingroup windmill windmill
  
  RUN cp -r /root/.cache /home/windmill/.cache
  
  RUN mkdir -p /tmp/windmill/logs && \
      mkdir -p /tmp/windmill/search
  
  # Make directories world-readable and writable
  RUN chmod -R 777 ${APP} && \
      chmod -R 777 /tmp/windmill && \
      chmod -R 777 /home/windmill/.cache
  
  # Copy application files
  COPY start.sh /app/code/start.sh
  COPY supervisord.conf /etc/supervisor/conf.d/windmill.conf
  COPY Caddyfile /app/code/Caddyfile
  COPY windmill/init-db-as-superuser.sql /app/code/init-db-as-superuser.sql

  # Create necessary directories
  # RUN mkdir -p /app/code/windmill /app/data /run/windmill /tmp/data /app/data/lsp_cache /app/data/windmill_index /app/data/postgresql /tmp/windmill/cache/py_runtime
  RUN mkdir -p /app/data/postgresql

  # Set permissions
  RUN chmod +x /app/code/start.sh && \
      chown -R cloudron:cloudron /app/data && \
      chown -R postgres:postgres /app/data/postgresql
  
  EXPOSE 8000

  # Set entrypoint
  CMD ["/app/code/start.sh"]
