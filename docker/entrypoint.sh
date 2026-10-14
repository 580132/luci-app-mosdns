#!/bin/sh
# Docker entrypoint for patched mosdns (no OpenWrt/LuCI).
# 1. Makes sure geo data (.dat) exists, optionally updates it.
# 2. Dumps geoip/geosite .txt files with geo2txt (replaces mosdns.uc v2dat_dump).
# 3. Applies LISTEN_*/API_*/LOG_* env overrides to the config file.
# 4. execs mosdns.
set -eu

CONFIG="${CONFIG:-/etc/mosdns/config.yaml}"
V2DAT_DIR="${V2DAT_DIR:-/usr/share/v2ray}"
TXT_DIR="${TXT_DIR:-/var/lib/mosdns}"
RULE_DIR="${RULE_DIR:-/etc/mosdns/rule}"
GEO_AUTO_UPDATE="${GEO_AUTO_UPDATE:-1}"
GEOIP_TYPE="${GEOIP_TYPE:-geoip-only-cn-private}"
GITHUB_PROXY="${GITHUB_PROXY:-}"
GEOSITE_TAGS="${GEOSITE_TAGS:-}"   # e.g. "apple,netflix,disney" (comma separated)
GEOIP_TAGS="${GEOIP_TAGS:-}"       # e.g. "us,hk" (comma separated)
APPLY_ENV_CONFIG="${APPLY_ENV_CONFIG:-1}"

LISTEN_ADDR="${LISTEN_ADDR:-0.0.0.0}"
LISTEN_PORT="${LISTEN_PORT:-53}"
API_LISTEN="${API_LISTEN:-0.0.0.0:9091}"
LOG_LEVEL="${LOG_LEVEL:-info}"
LOG_FILE="${LOG_FILE:-}"

# If the user passed mosdns args (default CMD does), honor -c/--config as CONFIG.
prev=""
for a in "$@"; do
    case "$a" in
        --config=*) CONFIG="${a#--config=}" ;;
        *) if [ "$prev" = "-c" ] || [ "$prev" = "--config" ]; then CONFIG="$a"; fi ;;
    esac
    prev="$a"
done

log() { printf '%s\n' "$*"; }

mkdir -p "$V2DAT_DIR" "$TXT_DIR" "$RULE_DIR" /var/log

# ---- rule placeholders (only when missing, e.g. fresh empty volume) ----
for f in whitelist blocklist hosts redirect greylist ddnslist streaming local-ptr cloudflare-cidr; do
    if [ ! -f "$RULE_DIR/$f.txt" ]; then
        printf '# MosDNS Rules\n' > "$RULE_DIR/$f.txt"
    fi
done

# ---- geo data download (replaces mosdns.uc update_geodat, no uci needed) ----
GEO_BASE="https://github.com/Loyalsoldier/geoip/releases/latest/download/${GEOIP_TYPE}.dat"
SITE_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"
if [ -n "$GITHUB_PROXY" ]; then
    # normalize trailing slash
    case "$GITHUB_PROXY" in */) ;; *) GITHUB_PROXY="$GITHUB_PROXY/";; esac
    GEO_BASE="${GITHUB_PROXY}${GEO_BASE}"
    SITE_URL="${GITHUB_PROXY}${SITE_URL}"
fi

download() { # $1=url $2=dest
    log "Downloading $1"
    curl -fsSL --connect-timeout 10 --retry 2 -o "$2" "$1"
}

fetch_dat() { # $1=url $2=localfile
    url="$1"; local_file="$2"; tmp_file="${local_file}.tmp"
    if [ ! -f "$local_file" ]; then
        download "$url" "$tmp_file" && mv -f "$tmp_file" "$local_file"
        return $?
    fi
    if [ "$GEO_AUTO_UPDATE" != "1" ]; then
        return 0
    fi
    if download "${url}.sha256sum" "${tmp_file}.sha256sum"; then
        remote_sum="$(cut -d' ' -f1 "${tmp_file}.sha256sum")"
        local_sum="$(sha256sum "$local_file" | cut -d' ' -f1)"
        rm -f "${tmp_file}.sha256sum"
        if [ "$remote_sum" = "$local_sum" ]; then
            log "$local_file is up to date."
            return 0
        fi
        log "$local_file is outdated, updating..."
        download "$url" "$tmp_file" || return 1
        if [ "$(sha256sum "$tmp_file" | cut -d' ' -f1)" != "$remote_sum" ]; then
            log "Checksum mismatch for $local_file, keeping old file."
            rm -f "$tmp_file"
            return 1
        fi
        mv -f "$tmp_file" "$local_file"
    else
        log "Checksum download failed, keeping existing $local_file."
        rm -f "${tmp_file}.sha256sum"
    fi
    return 0
}

geo_ok=1
fetch_dat "$GEO_BASE" "$V2DAT_DIR/geoip.dat" || geo_ok=0
fetch_dat "$SITE_URL" "$V2DAT_DIR/geosite.dat" || geo_ok=0

# ---- dump txt rules with geo2txt (replaces mosdns.uc v2dat_dump) ----
if [ -f "$V2DAT_DIR/geoip.dat" ] && [ -f "$V2DAT_DIR/geosite.dat" ]; then
    geo2txt geoip -f "$V2DAT_DIR/geoip.dat" -e cn -o "$TXT_DIR"
    geo2txt geosite -f "$V2DAT_DIR/geosite.dat" -e cn -e 'geolocation-!cn' -o "$TXT_DIR"
    if [ -n "$GEOIP_TAGS" ]; then
        tags="$(printf '%s' "$GEOIP_TAGS" | tr ',' ' ')"
        # shellcheck disable=SC2086
        geo2txt geoip -f "$V2DAT_DIR/geoip.dat" $(
            for t in $tags; do printf '%s' "-e $t "; done
        ) -o "$TXT_DIR"
    fi
    if [ -n "$GEOSITE_TAGS" ]; then
        tags="$(printf '%s' "$GEOSITE_TAGS" | tr ',' ' ')"
        # shellcheck disable=SC2086
        geo2txt geosite -f "$V2DAT_DIR/geosite.dat" $(
            for t in $tags; do printf '%s' "-e $t "; done
        ) -o "$TXT_DIR"
    fi
else
    log "WARNING: geo .dat files missing and download failed (offline?)."
    geo_ok=0
fi

# The default config references these files; fail fast with a clear message.
for need in "$TXT_DIR/geosite_cn.txt" "$TXT_DIR/geoip_cn.txt" "$TXT_DIR/geosite_geolocation-!cn.txt"; do
    if [ ! -f "$need" ]; then
        log "ERROR: required geo file $need not found. Check network or mount it manually."
        [ "$geo_ok" = "1" ] || exit 1
    fi
done

# ---- env overrides for the stock config (skip with APPLY_ENV_CONFIG=0) ----
# NOTE: never sed -i the config in place: it is commonly a (read-only) bind
# mount, and renaming over a mount point fails with "Resource busy".
# Work on a temp copy and point mosdns at it instead.
if [ "$APPLY_ENV_CONFIG" = "1" ] && [ -f "$CONFIG" ]; then
    # busybox mktemp requires TEMPLATE to end with XXXXXX, and mosdns/viper
    # picks the config parser by file extension, so use a temp dir + fixed name.
    TMP_DIR="$(mktemp -d /tmp/mosdns.XXXXXX)"
    TMP_CONFIG="$TMP_DIR/config.yaml"
    cp -f "$CONFIG" "$TMP_CONFIG"
    sed -i "s#\(listen:[[:space:]]*\"\)[^\"]*\(\"\)#\1${LISTEN_ADDR}:${LISTEN_PORT}\2#g" "$TMP_CONFIG"
    sed -i "s#\(http:[[:space:]]*\"\)[^\"]*\(\"\)#\1${API_LISTEN}\2#" "$TMP_CONFIG"
    sed -i "s#\(level:[[:space:]]*\).*#\1${LOG_LEVEL}#" "$TMP_CONFIG"
    # NOTE: `file:` is anchored to line start so cache/stats `dump_file:` is untouched.
    sed -i "s#^\([[:space:]]*file:[[:space:]]*\"\)[^\"]*\(\"\)#\1${LOG_FILE}\2#" "$TMP_CONFIG"

    # Rewrite the -c/--config argument to the temp copy, keep all other args.
    saved_n=$#
    i=1
    while [ "$i" -le "$saved_n" ]; do
        eval "o_$i=\${$i}"
        i=$((i + 1))
    done
    set --
    i=1
    prev=""
    while [ "$i" -le "$saved_n" ]; do
        eval "orig=\$o_$i"
        arg="$orig"
        case "$orig" in
            --config=*) arg="--config=$TMP_CONFIG" ;;
            *) if [ "$prev" = "-c" ] || [ "$prev" = "--config" ]; then arg="$TMP_CONFIG"; fi ;;
        esac
        prev="$orig"
        set -- "$@" "$arg"
        i=$((i + 1))
    done
    i=1
    while [ "$i" -le "$saved_n" ]; do
        eval "unset o_$i"
        i=$((i + 1))
    done
    CONFIG="$TMP_CONFIG"
fi

log "Starting: mosdns $* (config: $CONFIG)"

# Standalone stats dashboard (replaces the LuCI statistics view).
# busybox httpd is part of the alpine base image; empty STATS_UI_PORT disables it.
if [ -n "${STATS_UI_PORT:-}" ] && [ -d /usr/share/mosdns-stats ]; then
    log "Serving stats dashboard on :${STATS_UI_PORT}"
    busybox httpd -p "$STATS_UI_PORT" -h /usr/share/mosdns-stats
fi

exec /usr/bin/mosdns "$@"
