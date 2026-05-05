# =============================================================================
# Windmill Cloudron Dockerfile
# Source build with --features oss, adapted from upstream v1.695.0
# Base image: cloudron/base:5.0.0 with embedded PostgreSQL 16
#
# Stage structure:
#   runtime-bin-stages → rust_base → duckdb_ffi_builder → frontend → planner → builder → final
#
# Context: jj:yrmvpkkz
# =============================================================================

ARG DEBIAN_IMAGE=cloudron/base:5.0.0
ARG RUST_IMAGE=rust:1.93-slim-bookworm

# =============================================================================
# RUNTIME BINARY STAGES — platform-pinned to amd64
# COPY --from=<image> resolves the image using the build HOST's platform, not
# the target stage's platform. When building on arm64 (e.g. Apple Silicon) for
# an amd64 Cloudron server, this silently copies arm64 binaries into an amd64
# container, causing "Exec format error" (ENOEXEC) at runtime.
# Pinning these as named stages with --platform=linux/amd64 forces the correct
# architecture regardless of build host. Context: jj:yrmvpkkz
# =============================================================================
FROM --platform=linux/amd64 denoland/deno:2.2.1 AS deno-bin
FROM --platform=linux/amd64 oven/bun:1.3.10 AS bun-bin
FROM --platform=linux/amd64 php:8.3.30-cli-bookworm AS php-bin
FROM --platform=linux/amd64 composer:2.9.5 AS composer-bin
FROM --platform=linux/amd64 docker:29-dind AS docker-bin

# =============================================================================
# RUST BASE — shared by planner, builder, and duckdb_ffi stages
# =============================================================================
FROM --platform=linux/amd64 ${RUST_IMAGE} AS rust_base

# mold linker is REQUIRED — .cargo/config.toml sets rustflags = ["-C", "link-arg=-fuse-ld=mold"]
RUN apt-get update && apt-get install -y git libssl-dev pkg-config npm mold clang \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN apt-get -y update \
    && apt-get install -y curl nodejs \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN rustup component add rustfmt

RUN CARGO_NET_GIT_FETCH_WITH_CLI=true cargo install cargo-chef --version 0.1.68
RUN cargo install sccache --version ^0.8
ENV RUSTC_WRAPPER=sccache SCCACHE_DIR=/backend/sccache

WORKDIR /windmill

ENV SQLX_OFFLINE=true

# =============================================================================
# DUCKDB FFI BUILDER — builds libwindmill_duckdb_ffi_internal.so
# Required because oss → all_languages → duckdb, and the .so is loaded at runtime
# via libloading (not linked at compile time by the main cargo build)
# =============================================================================
FROM --platform=linux/amd64 rust_base AS windmill_duckdb_ffi_internal_builder

WORKDIR /windmill-duckdb-ffi-internal

RUN apt-get update && apt-get install -y clang=1:14.0-55.* libclang-dev=1:14.0-55.* cmake=3.25.* \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

COPY windmill-fork/backend/windmill-duckdb-ffi-internal .

RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=$SCCACHE_DIR,sharing=locked \
    cargo build --release -p windmill_duckdb_ffi_internal

# =============================================================================
# FRONTEND — builds the svelte static frontend
# =============================================================================
FROM --platform=linux/amd64 node:24-alpine AS frontend

WORKDIR /frontend
COPY windmill-fork/frontend/package.json windmill-fork/frontend/package-lock.json windmill-fork/frontend/.npmrc ./
COPY windmill-fork/frontend/scripts/ ./scripts/
RUN npm ci

# Copy all frontend source
COPY windmill-fork/frontend .
RUN mkdir /backend
COPY windmill-fork/backend/windmill-api/openapi.yaml /backend/windmill-api/openapi.yaml
COPY windmill-fork/openflow.openapi.yaml /openflow.openapi.yaml
COPY windmill-fork/backend/windmill-api/build_openapi.sh /backend/windmill-api/build_openapi.sh
COPY windmill-fork/system_prompts/auto-generated /system_prompts/auto-generated

RUN cd /backend/windmill-api && . ./build_openapi.sh
COPY windmill-fork/backend/parsers/windmill-parser-wasm/pkg/ /backend/parsers/windmill-parser-wasm/pkg/
COPY windmill-fork/typescript-client/docs/ /frontend/static/tsdocs/
COPY windmill-fork/python-client/docs/ /frontend/static/pydocs/

RUN npm run generate-backend-client
ENV NODE_OPTIONS="--max-old-space-size=8192"
ARG VITE_BASE_URL ""
# -- MACRO-SPREAD-WASM-PARSER-DEV-ONLY -- #
RUN npm run build

# =============================================================================
# PLANNER — cargo-chef prepare (generates recipe.json for dependency caching)
# =============================================================================
FROM --platform=linux/amd64 rust_base AS planner

COPY windmill-fork/openflow.openapi.yaml /openflow.openapi.yaml
COPY windmill-fork/backend ./

RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=$SCCACHE_DIR,sharing=locked \
    CARGO_NET_GIT_FETCH_WITH_CLI=true cargo chef prepare --recipe-path recipe.json

# =============================================================================
# BUILDER — compiles the windmill binary
# Uses oss_core + all_languages (NOT "oss" which includes no_auth, breaking password login)
# =============================================================================
FROM --platform=linux/amd64 rust_base AS builder
ARG features="oss_core,all_languages"

COPY --from=planner /windmill/recipe.json recipe.json

# All compile-time deps including libkrb5 (mssql-kerberos via all_languages → oss)
RUN apt-get update && apt-get install -y \
    libxml2-dev=2.9.* libxmlsec1-dev=1.2.* \
    libkrb5-dev libsasl2-dev libcurl4-openssl-dev \
    clang=1:14.0-55.* libclang-dev=1:14.0-55.* cmake=3.25.* \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Cook dependencies from recipe (cached layer — survives source changes)
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=$SCCACHE_DIR,sharing=locked \
    CARGO_NET_GIT_FETCH_WITH_CLI=true RUST_BACKTRACE=1 cargo chef cook --release --features "$features" --recipe-path recipe.json

# Copy fork source
COPY windmill-fork/openflow.openapi.yaml /openflow.openapi.yaml
COPY windmill-fork/backend ./

RUN mkdir -p /frontend

COPY --from=frontend /frontend/build /frontend/build
COPY --from=frontend /backend/windmill-api/openapi-deref.yaml ./windmill-api/openapi-deref.yaml

# Build windmill binary
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=$SCCACHE_DIR,sharing=locked \
    CARGO_NET_GIT_FETCH_WITH_CLI=true cargo build --release --features "$features"

# Strip binary and split debug info (~100MB+ savings)
RUN objcopy --only-keep-debug /windmill/target/release/windmill /windmill/target/release/windmill.debug \
    && strip /windmill/target/release/windmill \
    && objcopy --add-gnu-debuglink=/windmill/target/release/windmill.debug /windmill/target/release/windmill

# =============================================================================
# FINAL STAGE — Cloudron runtime image
# Diverges from upstream: cloudron/base instead of debian, embedded PG 16,
# Caddy reverse proxy, supervisord, no nsjail (see Learnings §1)
# =============================================================================
FROM ${DEBIAN_IMAGE}

ARG TARGETPLATFORM
ARG GO_VERSION=1.26.0
ARG APP=/app/code
ARG features="oss_core,all_languages"

# Python version — must match upstream v1.695.0
ARG LATEST_STABLE_PY=3.12
ENV UV_PYTHON_INSTALL_DIR=/tmp/windmill/cache/py_runtime
ENV UV_PYTHON_PREFERENCE=only-managed

RUN mkdir -p /usr/local/uv
ENV UV_TOOL_BIN_DIR=/usr/local/bin
ENV UV_TOOL_DIR=/usr/local/uv

ENV PATH=/usr/local/bin:/root/.local/bin:/tmp/.local/bin:$PATH

# ---------------------------------------------------------------------------
# Install PostgreSQL 16 from official apt repository
# (cloudron/base comes with PG 14 — we need 16 for upstream compatibility)
# ---------------------------------------------------------------------------
RUN apt-get update && apt-get install -y gnupg lsb-release curl ca-certificates \
    && curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
       | gpg --dearmor -o /usr/share/keyrings/postgresql-archive-keyring.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/postgresql-archive-keyring.gpg] https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
       > /etc/apt/sources.list.d/pgdg.list \
    && apt-get update \
    && apt-get install -y postgresql-16 postgresql-client-16 postgresql-contrib-16 \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# Base runtime dependencies
# ---------------------------------------------------------------------------
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       netbase tzdata ca-certificates wget curl jq unzip \
       build-essential git gosu supervisor \
       software-properties-common gnupg lsb-release \
       unixodbc xmlsec1 procps \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# Caddy (official apt repository)
# ---------------------------------------------------------------------------
RUN apt-get update && \
    apt-get install -y debian-keyring debian-archive-keyring && \
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg && \
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list && \
    apt-get update && \
    apt-get install -y caddy && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# Go
# ---------------------------------------------------------------------------
RUN curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" | tar -C /usr/local -xz

ENV PATH="${PATH}:/usr/local/go/bin"
ENV GO_PATH=/usr/local/go/bin/go

# ---------------------------------------------------------------------------
# UV + Python runtimes (build-cache staging pattern — see Learnings §3)
# ---------------------------------------------------------------------------
RUN curl --proto '=https' --tlsv1.2 -LsSf https://github.com/astral-sh/uv/releases/download/0.9.24/uv-installer.sh | sh \
    && mv /root/.local/bin/uv /usr/local/bin/uv

# Install to temp build location first, then copy with correct permissions
RUN UV_CACHE_DIR=/tmp/build_cache/uv UV_PYTHON_INSTALL_DIR=/tmp/build_cache/py_runtime uv python install 3.11
RUN UV_CACHE_DIR=/tmp/build_cache/uv UV_PYTHON_INSTALL_DIR=/tmp/build_cache/py_runtime uv python install $LATEST_STABLE_PY

# ---------------------------------------------------------------------------
# Node.js 20 (runtime — frontend BUILD uses node:24-alpine)
# ---------------------------------------------------------------------------
RUN curl -sL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get -y update && apt-get install -y nodejs \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# Go build warm-up — matches windmill's Go wrapper structure (see Learnings §7)
# ---------------------------------------------------------------------------
RUN export GOCACHE=/tmp/build_cache/go && \
    mkdir -p /tmp/gobuildwarm/inner && \
    cd /tmp/gobuildwarm && \
    go mod init mymod && \
    printf 'package main\nimport (\n\t"encoding/json"\n\t"os"\n\t"fmt"\n\t"mymod/inner"\n)\nfunc main() {\n\tdat, _ := os.ReadFile("args.json")\n\tvar req inner.Req\n\tjson.Unmarshal(dat, &req)\n\tres, _ := inner.Run(req)\n\tres_json, _ := json.Marshal(res)\n\tfmt.Println(string(res_json))\n}' > main.go && \
    printf 'package inner\ntype Req struct {\n\tX int `json:"x"`\n}\nfunc Run(req Req) (interface{}, error) {\n\treturn main(req.X)\n}\nfunc main(x int) (interface{}, error) {\n\treturn x, nil\n}' > inner/inner.go && \
    go build -x . && \
    rm -rf /tmp/gobuildwarm

# ---------------------------------------------------------------------------
# Copy build caches to final location with world-writable permissions
# chmod a+rw adds read+write WITHOUT removing execute bits (755→777, 644→666)
# ---------------------------------------------------------------------------
RUN mkdir -p /tmp/windmill/cache && \
    cp -r /tmp/build_cache/* /tmp/windmill/cache/ && \
    chmod -R a+rw /tmp/windmill/cache && \
    rm -rf /tmp/build_cache && \
    mkdir -p -m 777 /tmp/windmill/cache/uv /tmp/windmill/cache/go /tmp/windmill/cache/rustup /tmp/windmill/cache/cargo

# Runtime cache environment variables (writable by cloudron:cloudron)
ENV UV_CACHE_DIR=/tmp/windmill/cache/uv
ENV UV_PYTHON_INSTALL_DIR=/tmp/windmill/cache/py_runtime
ENV GOCACHE=/tmp/windmill/cache/go
ENV RUSTUP_HOME="/tmp/windmill/cache/rustup"
ENV CARGO_HOME="/tmp/windmill/cache/cargo"
ENV LD_LIBRARY_PATH="."

ENV TZ=Etc/UTC

# ---------------------------------------------------------------------------
# Copy compiled artifacts from builder stages
# ---------------------------------------------------------------------------
COPY --from=builder /frontend/build /static_frontend
COPY --from=builder /windmill/target/release/windmill ${APP}/windmill
COPY --from=windmill_duckdb_ffi_internal_builder /windmill-duckdb-ffi-internal/target/release/libwindmill_duckdb_ffi_internal.so ${APP}/libwindmill_duckdb_ffi_internal.so

# ---------------------------------------------------------------------------
# Runtime binaries from platform-pinned stages (see top of file)
# ---------------------------------------------------------------------------
COPY --from=deno-bin --chmod=755 /usr/bin/deno /usr/bin/deno

COPY --from=bun-bin /usr/local/bin/bun /usr/bin/bun

COPY --from=php-bin /usr/local/bin/php /usr/bin/php
COPY --from=composer-bin /usr/bin/composer /usr/bin/composer

# Docker client (for LSP sidecar management via Cloudron docker addon)
COPY --from=docker-bin /usr/local/bin/docker /usr/local/bin/

# ---------------------------------------------------------------------------
# Windmill binary setup + hub cache pre-warm
# ---------------------------------------------------------------------------
WORKDIR ${APP}

RUN ln -s ${APP}/windmill /usr/local/bin/windmill

COPY windmill-fork/frontend/src/lib/hubPaths.json ${APP}/hubPaths.json

RUN windmill cache ${APP}/hubPaths.json && rm ${APP}/hubPaths.json

RUN windmill cache-rt

# ---------------------------------------------------------------------------
# Windmill user — cloudron/base:5.0.0 already provides cloudron:cloudron at
# UID/GID 1000, which is what supervisord runs windmill as. No need to create
# a separate windmill user. Upstream does this for bare Debian images only.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Temp directories and permissions
# ---------------------------------------------------------------------------
RUN mkdir -p -m 777 /tmp/windmill/logs /tmp/windmill/search /tmp/.cache && chmod 777 /tmp/.cache

# Make directories world-accessible for any UID
RUN find ${APP} /tmp/windmill -type d -exec chmod 777 {} +

# ---------------------------------------------------------------------------
# Cloudron-specific files
# ---------------------------------------------------------------------------
COPY start.sh /app/code/start.sh
COPY inject-credentials.sh /app/code/inject-credentials.sh
COPY supervisord.conf /etc/supervisor/conf.d/windmill.conf
COPY Caddyfile /app/code/Caddyfile
COPY windmill/init-db-as-superuser.sql /app/code/init-db-as-superuser.sql

# ---------------------------------------------------------------------------
# PostgreSQL data directory and permissions
# ---------------------------------------------------------------------------
RUN mkdir -p /app/data/postgresql

RUN chmod +x /app/code/start.sh /app/code/inject-credentials.sh && \
    chown -R cloudron:cloudron /app/data && \
    chown -R postgres:postgres /app/data/postgresql

EXPOSE 8000

CMD ["/app/code/start.sh"]