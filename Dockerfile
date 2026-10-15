# syntax=docker/dockerfile:1

# mosdns (OpenWrt sbwml fork, all mosdns/patches applied) as a Docker image.
# LuCI / uci / procd parts are intentionally dropped: the image ships only
# the patched mosdns binary + geo2txt + a plain config.yaml + entrypoint.
#
# Build:
#   docker build -t mosdns:5.3.4 .
#   docker build --build-arg MOSDNS_VERSION=5.3.4 --build-arg MOSDNS_RELEASE=14 -t mosdns .
# Run:
#   docker run -d --name mosdns -p 53:53/udp -p 53:53/tcp mosdns:5.3.4

ARG MOSDNS_VERSION=5.3.4
ARG MOSDNS_RELEASE=14
ARG GEO2TXT_VERSION=1.0.0
ARG GO_IMAGE=golang:1.26-bookworm

# ---------------------------------------------------------------- builder: mosdns
FROM ${GO_IMAGE} AS mosdns-builder
ARG MOSDNS_VERSION
ARG MOSDNS_RELEASE
ARG MOSDNS_HASH=0302a685db2a6c3c09af7bf4ff0dffd24f1e583383a47f064564f5270033671b

RUN apt-get update \
    && apt-get install -y --no-install-recommends patch ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src

# Source tarball is the same one referenced by mosdns/Makefile (PKG_SOURCE_URL).
RUN curl -fsSL "https://codeload.github.com/IrineSistiana/mosdns/tar.gz/v${MOSDNS_VERSION}" -o mosdns.tar.gz \
    && echo "${MOSDNS_HASH}  mosdns.tar.gz" | sha256sum -c - \
    && tar xzf mosdns.tar.gz --strip-components=1 \
    && rm mosdns.tar.gz

# Apply every OpenWrt patch (adblock_set, stats_api, cache prefetch,
# mlog rotation, fallback fixes, ...). Sorted order == filename order.
COPY mosdns/patches/ ./patches/
RUN set -e; \
    for p in $(ls patches/*.patch | sort); do \
        echo "==> Applying $p"; \
        patch -p1 < "$p"; \
    done

# mosdns main package lives at the repo root (main.go), version string
# matches the OpenWrt Makefile: -X main.version=v<VERSION>-r<RELEASE>.
ARG TARGETARCH
RUN set -e; \
    export CGO_ENABLED=0; \
    export GOARCH="${TARGETARCH:-amd64}"; \
    go env GOVERSION GOARCH; \
    go build -trimpath \
        -ldflags "-s -w -X main.version=v${MOSDNS_VERSION}-r${MOSDNS_RELEASE}" \
        -o /out/mosdns . \
    && /out/mosdns version

# ---------------------------------------------------------------- builder: geo2txt (pure C, see geo2txt/Makefile)
FROM alpine:3.21 AS geo2txt-builder
ARG GEO2TXT_VERSION
RUN apk add --no-cache build-base curl
WORKDIR /src
RUN curl -fsSL "https://codeload.github.com/sbwml/geo2txt/tar.gz/${GEO2TXT_VERSION}" -o geo2txt.tar.gz \
    && tar xzf geo2txt.tar.gz --strip-components=1 \
    && rm geo2txt.tar.gz \
    && make static \
    && ./geo2txt --help 2>&1 | head -5; \
    mkdir -p /out && cp -a geo2txt /out/geo2txt

# ---------------------------------------------------------------- runtime
FROM alpine:3.21
LABEL org.opencontainers.image.title="mosdns (sbwml patched, no LuCI)"
LABEL org.opencontainers.image.source="https://github.com/sbwml/luci-app-mosdns"
LABEL org.opencontainers.image.description="Patched mosdns DNS forwarder without OpenWrt/LuCI dependencies"

RUN apk add --no-cache ca-certificates curl tzdata darkhttpd \
    && rm -rf /var/cache/apk/*

COPY --from=mosdns-builder /out/mosdns /usr/bin/mosdns
COPY --from=geo2txt-builder /out/geo2txt /usr/bin/geo2txt

# Default config (no uci/procd templating) + rule placeholders.
# Mount your own files to override: -v ./my-config.yaml:/etc/mosdns/config.yaml:ro
COPY docker/config.yaml /etc/mosdns/config.yaml
COPY luci-app-mosdns/root/etc/mosdns/rule/ /etc/mosdns/rule/
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY docker/update-data.sh /usr/local/bin/update-data
# Standalone stats dashboard (replaces the LuCI statistics.js view).
# Served by busybox httpd; the page calls the stats_api HTTP endpoints directly
# (CORS is already Access-Control-Allow-Origin: * in the patched plugin).
COPY docker/stats/ /usr/share/mosdns-stats/
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/update-data \
    && mkdir -p /var/lib/mosdns /usr/share/v2ray /var/log

ENV CONFIG=/etc/mosdns/config.yaml \
    LISTEN_ADDR=0.0.0.0 \
    LISTEN_PORT=53 \
    API_LISTEN=0.0.0.0:9091 \
    LOG_LEVEL=info \
    LOG_FILE="" \
    GEO_AUTO_UPDATE=1 \
    GEOIP_TYPE=geoip-only-cn-private \
    GITHUB_PROXY="" \
    STATS_UI_PORT=8080 \
    ADBLOCK=0 \
    AD_SOURCES="" \
    AD_UPDATE_INTERVAL=604800 \
    AUTO_UPDATE=1 \
    UPDATE_CHECK_INTERVAL=86400

EXPOSE 53/udp 53/tcp 9091/tcp 8080/tcp

VOLUME ["/etc/mosdns", "/var/lib/mosdns", "/usr/share/v2ray"]

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["start", "-c", "/etc/mosdns/config.yaml", "-d", "/etc/mosdns"]
