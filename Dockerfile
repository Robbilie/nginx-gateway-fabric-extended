# =============================================================================
# Custom NGINX Gateway Fabric Image
# Adds: ngx_http_lua_module (OpenResty LuaJIT) + ngx_http_set_misc_module
# Note: auth_request is already included in the official NGF NGINX image.
# =============================================================================

FROM alpine:3.21 AS builder

ARG NGINX_VERSION=1.29.7
ARG LUA_NGINX_MODULE_VERSION=0.10.29
ARG NGX_DEVEL_KIT_VERSION=0.3.3
ARG LUA_CJSON_VERSION=2.1.0.14
ARG SET_MISC_MODULE_VERSION=0.33

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

# ngx_devel_kit (required by both lua-nginx-module and set-misc)
RUN wget -q "https://github.com/vision5/ngx_devel_kit/archive/v${NGX_DEVEL_KIT_VERSION}.tar.gz" -O ndk.tar.gz \
    && tar -xzf ndk.tar.gz

# lua-nginx-module
RUN wget -q "https://github.com/openresty/lua-nginx-module/archive/v${LUA_NGINX_MODULE_VERSION}.tar.gz" -O lua-nginx.tar.gz \
    && tar -xzf lua-nginx.tar.gz

# set-misc-nginx-module
RUN wget -q "https://github.com/openresty/set-misc-nginx-module/archive/v${SET_MISC_MODULE_VERSION}.tar.gz" -O set-misc.tar.gz \
    && tar -xzf set-misc.tar.gz

# NGINX source -- version must match the NGF image exactly
RUN wget -q "https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz" -O nginx.tar.gz \
    && tar -xzf nginx.tar.gz

# Compile all three as dynamic modules
RUN cd "nginx-${NGINX_VERSION}" \
    && ./configure \
        --with-compat \
        --add-dynamic-module="/build/ngx_devel_kit-${NGX_DEVEL_KIT_VERSION}" \
        --add-dynamic-module="/build/lua-nginx-module-${LUA_NGINX_MODULE_VERSION}" \
        --add-dynamic-module="/build/set-misc-nginx-module-${SET_MISC_MODULE_VERSION}" \
        --with-ld-opt="-Wl,-rpath,${LUAJIT_LIB}" \
    && make modules

# lua-cjson
RUN wget -q "https://github.com/openresty/lua-cjson/archive/${LUA_CJSON_VERSION}.tar.gz" -O cjson.tar.gz \
    && tar -xzf cjson.tar.gz \
    && cd "lua-cjson-${LUA_CJSON_VERSION}" \
    && make LUA_INCLUDE_DIR=${LUAJIT_INC} \
    && make install PREFIX=/usr/local CJSON_CMODULE_DIR=/usr/local/lib/lua/5.1

# =============================================================================
# Final image
# =============================================================================
FROM ghcr.io/nginx/nginx-gateway-fabric/nginx:2.5.0

USER root

COPY --from=builder /build/nginx-*/objs/ndk_http_module.so          /etc/nginx/modules/
COPY --from=builder /build/nginx-*/objs/ngx_http_lua_module.so      /etc/nginx/modules/
COPY --from=builder /build/nginx-*/objs/ngx_http_set_misc_module.so /etc/nginx/modules/

RUN apk add --no-cache luajit
RUN apk add --no-cache lua-resty-core lua-resty-lrucache

COPY --from=builder /usr/local/lib/lua /usr/local/lib/lua

USER 101
