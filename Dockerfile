# =============================================================================
# Custom NGINX Gateway Fabric Image
# Adds: ngx_http_lua_module (OpenResty LuaJIT) on top of the official image
# Note: auth_request is already included in the official NGF NGINX image.
# =============================================================================
ARG NGF_VERSION=1.4.0
FROM ghcr.io/nginxinc/nginx-gateway-fabric/nginx:${NGF_VERSION} AS base

# =============================================================================
# Builder stage -- compile Lua as a dynamic module against NGINX source
# =============================================================================
FROM debian:bookworm-slim AS builder

ARG NGINX_VERSION=1.27.2
ARG LUAJIT_VERSION=2.1-20240314
ARG LUA_NGINX_MODULE_VERSION=0.10.27
ARG NGX_DEVEL_KIT_VERSION=0.3.3
ARG LUA_RESTY_CORE_VERSION=0.1.29
ARG LUA_RESTY_LRUCACHE_VERSION=0.14

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    libpcre3-dev \
    libssl-dev \
    zlib1g-dev \
    wget \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# LuaJIT
RUN wget -q "https://github.com/openresty/luajit2/archive/v${LUAJIT_VERSION}.tar.gz" -O luajit.tar.gz \
    && tar -xzf luajit.tar.gz \
    && cd "luajit2-${LUAJIT_VERSION}" \
    && make -j"$(nproc)" \
    && make install PREFIX=/usr/local/luajit

ENV LUAJIT_LIB=/usr/local/luajit/lib
ENV LUAJIT_INC=/usr/local/luajit/include/luajit-2.1

# ngx_devel_kit (NDK) -- required by lua-nginx-module
RUN wget -q "https://github.com/vision5/ngx_devel_kit/archive/v${NGX_DEVEL_KIT_VERSION}.tar.gz" -O ndk.tar.gz \
    && tar -xzf ndk.tar.gz

# lua-nginx-module
RUN wget -q "https://github.com/openresty/lua-nginx-module/archive/v${LUA_NGINX_MODULE_VERSION}.tar.gz" -O lua-nginx.tar.gz \
    && tar -xzf lua-nginx.tar.gz

# NGINX source (needed to compile dynamic modules)
RUN wget -q "https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz" -O nginx.tar.gz \
    && tar -xzf nginx.tar.gz

# Build as dynamic modules (.so) -- avoids replacing the NGINX binary entirely
RUN cd "nginx-${NGINX_VERSION}" \
    && ./configure \
        --with-compat \
        --add-dynamic-module="/build/ngx_devel_kit-${NGX_DEVEL_KIT_VERSION}" \
        --add-dynamic-module="/build/lua-nginx-module-${LUA_NGINX_MODULE_VERSION}" \
        --with-ld-opt="-Wl,-rpath,${LUAJIT_LIB}" \
    && make modules

# lua-resty-core and lua-resty-lrucache (required runtime libs)
RUN wget -q "https://github.com/openresty/lua-resty-core/archive/v${LUA_RESTY_CORE_VERSION}.tar.gz" -O resty-core.tar.gz \
    && tar -xzf resty-core.tar.gz \
    && cd "lua-resty-core-${LUA_RESTY_CORE_VERSION}" \
    && make install PREFIX=/usr/local/nginx-lua

RUN wget -q "https://github.com/openresty/lua-resty-lrucache/archive/v${LUA_RESTY_LRUCACHE_VERSION}.tar.gz" -O resty-lrucache.tar.gz \
    && tar -xzf resty-lrucache.tar.gz \
    && cd "lua-resty-lrucache-${LUA_RESTY_LRUCACHE_VERSION}" \
    && make install PREFIX=/usr/local/nginx-lua

# =============================================================================
# Final image -- layer Lua on top of the unmodified official NGF image
# =============================================================================
FROM base

USER root

# Runtime dep for LuaJIT shared library (Alpine-based image)
RUN apk add --no-cache libpcre

# Dynamic module .so files
COPY --from=builder /build/nginx-*/objs/ndk_http_module.so      /usr/lib64/nginx/modules/
COPY --from=builder /build/nginx-*/objs/ngx_http_lua_module.so  /usr/lib64/nginx/modules/

# LuaJIT runtime library
COPY --from=builder /usr/local/luajit/lib    /usr/local/luajit/lib

# lua-resty-core and lua-resty-lrucache
COPY --from=builder /usr/local/nginx-lua/lib /usr/local/lib/lua

# Register LuaJIT with the dynamic linker (Alpine uses /etc/ld-musl-*.path via symlinks;
# the rpath baked in at compile time handles this, but we symlink as a fallback)
RUN ln -sf /usr/local/luajit/lib/libluajit-5.1.so.2 /usr/local/lib/libluajit-5.1.so.2

# Load the dynamic modules -- must appear at the top of nginx.conf (main context)
RUN printf 'load_module modules/ndk_http_module.so;\nload_module modules/ngx_http_lua_module.so;\n' \
    > /etc/nginx/modules/lua.conf

# Optional: copy your own Lua scripts into the image
# COPY lua/ /etc/nginx/lua/

# Drop back to the non-root user the official image uses
USER 101
