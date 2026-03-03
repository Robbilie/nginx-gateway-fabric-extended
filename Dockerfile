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
ARG LUAJIT_VERSION=2.1-20250826
ARG LUA_NGINX_MODULE_VERSION=0.10.29
ARG NGX_DEVEL_KIT_VERSION=0.3.3
ARG LUA_RESTY_CORE_VERSION=0.1.32
ARG LUA_RESTY_LRUCACHE_VERSION=0.15

RUN apk add --no-cache build-base pcre-dev openssl-dev zlib-dev wget ca-certificates

WORKDIR /build

# LuaJIT
RUN wget -q "https://github.com/openresty/luajit2/archive/v${LUAJIT_VERSION}.tar.gz" -O luajit.tar.gz \
    && tar -xzf luajit.tar.gz \
    && cd "luajit2-${LUAJIT_VERSION}" \
    && make -j"$(nproc)" \
    && make install PREFIX=/usr/local/luajit

ENV LUAJIT_LIB=/usr/local/luajit/lib
ENV LUAJIT_INC=/usr/local/luajit/include/luajit-2.1

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

# lua-resty-core and lua-resty-lrucache (required runtime Lua libs)
RUN wget -q "https://github.com/openresty/lua-resty-core/archive/v${LUA_RESTY_CORE_VERSION}.tar.gz" -O resty-core.tar.gz \
    && tar -xzf resty-core.tar.gz \
    && cd "lua-resty-core-${LUA_RESTY_CORE_VERSION}" \
    && make install PREFIX=/usr/local/nginx-lua

RUN wget -q "https://github.com/openresty/lua-resty-lrucache/archive/v${LUA_RESTY_LRUCACHE_VERSION}.tar.gz" -O resty-lrucache.tar.gz \
    && tar -xzf resty-lrucache.tar.gz \
    && cd "lua-resty-lrucache-${LUA_RESTY_LRUCACHE_VERSION}" \
    && make install PREFIX=/usr/local/nginx-lua

# =============================================================================
# Final image -- layer Lua on top of the unmodified official NGF NGINX image.
# Referenced directly (no ARG alias) so Docker uses the correct entrypoint.
# =============================================================================
FROM ghcr.io/nginx/nginx-gateway-fabric/nginx:2.4.2

USER root

RUN apk add --no-cache pcre

# Dynamic module .so files
COPY --from=builder /build/nginx-*/objs/ndk_http_module.so     /etc/nginx/modules/
COPY --from=builder /build/nginx-*/objs/ngx_http_lua_module.so /etc/nginx/modules/

# LuaJIT runtime
COPY --from=builder /usr/local/luajit/lib    /usr/local/luajit/lib

# lua-resty libraries
COPY --from=builder /usr/local/nginx-lua/lib /usr/local/lib/lua

# Help the musl dynamic linker find LuaJIT (rpath handles it, symlink is a fallback)
RUN ln -sf /usr/local/luajit/lib/libluajit-5.1.so.2 /usr/local/lib/libluajit-5.1.so.2

# Place load_module directives in main-includes -- NGF includes this dir at the
# top of nginx.conf (main context), which is exactly where load_module must live.
RUN mkdir -p /etc/nginx/main-includes \
    && printf 'load_module modules/ndk_http_module.so;\nload_module modules/ngx_http_lua_module.so;\n' \
    > /etc/nginx/main-includes/lua.conf

# Optional: add your own Lua scripts
# COPY lua/ /etc/nginx/lua/

USER 101
