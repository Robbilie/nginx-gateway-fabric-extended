# =============================================================================
# Custom NGINX Gateway Fabric Image
# Adds: ngx_http_lua_module (OpenResty LuaJIT) on top of the official image
# Note: auth_request is already included in the official NGF NGINX image.
# =============================================================================

# =============================================================================
# Builder stage -- compile Lua as a dynamic module against NGINX source.
# Uses Alpine (musl libc) to match the NGF base image ABI.
# NGINX_VERSION must exactly match what NGF ships -- confirmed 1.29.5 from logs.
# =============================================================================
FROM alpine:3.21 AS builder

ARG NGINX_VERSION=1.29.5
ARG LUA_NGINX_MODULE_VERSION=0.10.29
ARG NGX_DEVEL_KIT_VERSION=0.3.3
ARG LUA_CJSON_VERSION=2.1.0.14

RUN apk add --no-cache \
    build-base \
    pcre2-dev \
    openssl-dev \
    zlib-dev \
    wget \
    ca-certificates \
    luajit-dev \
    lua-resty-core \
    lua-resty-lrucache

ENV LUAJIT_LIB=/usr/lib
ENV LUAJIT_INC=/usr/include/luajit-2.1

WORKDIR /build

# ngx_devel_kit (required by lua-nginx-module)
RUN wget -q "https://github.com/vision5/ngx_devel_kit/archive/v${NGX_DEVEL_KIT_VERSION}.tar.gz" -O ndk.tar.gz \
    && tar -xzf ndk.tar.gz

# lua-nginx-module
RUN wget -q "https://github.com/openresty/lua-nginx-module/archive/v${LUA_NGINX_MODULE_VERSION}.tar.gz" -O lua-nginx.tar.gz \
    && tar -xzf lua-nginx.tar.gz

# NGINX source -- version must match the NGF image exactly
RUN wget -q "https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz" -O nginx.tar.gz \
    && tar -xzf nginx.tar.gz

# Compile as dynamic modules only -- no binary replacement needed
RUN cd "nginx-${NGINX_VERSION}" \
    && ./configure \
        --with-compat \
        --add-dynamic-module="/build/ngx_devel_kit-${NGX_DEVEL_KIT_VERSION}" \
        --add-dynamic-module="/build/lua-nginx-module-${LUA_NGINX_MODULE_VERSION}" \
        --with-ld-opt="-Wl,-rpath,${LUAJIT_LIB}" \
    && make modules

# lua-cjson -- compiled against LuaJIT so it lands on the correct package.cpath
RUN wget -q "https://github.com/openresty/lua-cjson/archive/${LUA_CJSON_VERSION}.tar.gz" -O cjson.tar.gz \
    && tar -xzf cjson.tar.gz \
    && cd "lua-cjson-${LUA_CJSON_VERSION}" \
    && make LUA_INCLUDE_DIR=${LUAJIT_INC} \
    && make install PREFIX=/usr/local CJSON_CMODULE_DIR=/usr/local/lib/lua/5.1

# =============================================================================
# Final image -- layer Lua on top of the unmodified official NGF NGINX image.
# =============================================================================
FROM ghcr.io/nginx/nginx-gateway-fabric/nginx:2.4.2

USER root

# Dynamic module .so files
COPY --from=builder /build/nginx-*/objs/ndk_http_module.so     /etc/nginx/modules/
COPY --from=builder /build/nginx-*/objs/ngx_http_lua_module.so /etc/nginx/modules/

# LuaJIT runtime (Alpine package -- built from OpenResty luajit2 sources)
RUN apk add --no-cache luajit

# lua-resty libraries (Alpine packages -- built from official OpenResty sources)
RUN apk add --no-cache lua-resty-core lua-resty-lrucache

# lua-cjson C extension
COPY --from=builder /usr/local/lib/lua /usr/local/lib/lua

# Optional: add your own Lua scripts
# COPY lua/ /etc/nginx/lua/

USER 101
