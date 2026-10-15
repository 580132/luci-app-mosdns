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

# ---- data update: geo + adlist (port of `mosdns.uc update`) ----
# Best-effort at boot: an offline first start fails below with a clear message,
# a later offline restart keeps serving previous files.
# Refresh any time without restart: docker exec <container> update-data
# (mosdns picks up file changes automatically via its file watcher).
if [ -x /usr/local/bin/update-data ]; then
    /usr/local/bin/update-data || log "WARNING: data update failed at startup."
fi

# The default config references these files; fail fast with a clear message.
for need in "$TXT_DIR/geosite_cn.txt" "$TXT_DIR/geoip_cn.txt" "$TXT_DIR/geosite_geolocation-!cn.txt"; do
    if [ ! -f "$need" ]; then
        log "ERROR: required geo file $need not found. Check network or mount it manually."
        exit 1
    fi
done
# The adlist plugin requires its file to exist; guarantee a valid placeholder.
if [ ! -f "$TXT_DIR/adlist.txt" ]; then
    printf '# MosDNS adlist (placeholder)\n' > "$TXT_DIR/adlist.txt"
fi

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

# --- next_wait start ---
# next_wait "HH:MM[,HH:MM...]" -> prints seconds until the next occurrence.
# Pure arithmetic on date +%H/%M/%S (no date -d, portable across GNU/busybox).
next_wait() {
    items="$(printf '%s' "$1" | tr ',' ' ')"
    ch=$(date +%H | sed 's/^0*//'); [ -z "$ch" ] && ch=0
    cm=$(date +%M | sed 's/^0*//'); [ -z "$cm" ] && cm=0
    cs=$(date +%S | sed 's/^0*//'); [ -z "$cs" ] && cs=0
    cur=$((ch * 3600 + cm * 60 + cs))
    best=""
    # shellcheck disable=SC2086
    for t in $items; do
        t="$(printf '%s' "$t" | tr -d ' ')"
        case "$t" in
            [0-2][0-9]:[0-5][0-9]) ;;
            *) continue ;;
        esac
        h=${t%%:*}; m=${t##*:}
        h=$(printf '%s' "$h" | sed 's/^0*//'); [ -z "$h" ] && h=0
        m=$(printf '%s' "$m" | sed 's/^0*//'); [ -z "$m" ] && m=0
        [ "$h" -gt 23 ] && continue
        tgt=$((h * 3600 + m * 60))
        [ "$tgt" -le "$cur" ] && tgt=$((tgt + 86400))
        w=$((tgt - cur))
        if [ -z "$best" ] || [ "$w" -lt "$best" ]; then best="$w"; fi
    done
    [ -n "$best" ] || return 1
    printf '%s\n' "$best"
}
# --- next_wait end ---

# ---- periodic background refresh (zero-downtime) ----
# Dumps are published atomically and mosdns reloads changed files through its
# file watcher (patches 206/207), so DNS keeps serving while data refreshes.
# Two modes (AUTO_UPDATE=0 disables both; updates then only happen at
# container start or via `docker exec <ctr> update-data`):
#   UPDATE_AT=""            interval mode: run every UPDATE_CHECK_INTERVAL
#   UPDATE_AT="03:00[,15:00]" wall-clock mode: run at these local times daily
#                           (container TZ applies; image defaults to UTC)
# In both modes the freshness rules still apply (geo: sha256 compare; ads:
# re-download when older than UPDATE_CHECK_INTERVAL), so a run may legitimately
# download nothing.
if [ "${AUTO_UPDATE:-1}" = "1" ]; then
    (
        set +e
        if [ -n "${UPDATE_AT:-}" ]; then
            log "Background updater started (daily at ${UPDATE_AT}, TZ=${TZ:-UTC})."
            while true; do
                if wait_s="$(next_wait "$UPDATE_AT")"; then
                    sleep "$wait_s"
                    if [ -x /usr/local/bin/update-data ]; then
                        /usr/local/bin/update-data || log "WARNING: scheduled data update failed."
                    fi
                else
                    log "WARNING: invalid UPDATE_AT '$UPDATE_AT', retry in 1h."
                    sleep 3600
                fi
            done
        else
            interval="${UPDATE_CHECK_INTERVAL:-86400}"
            case "$interval" in ''|*[!0-9]*)
                log "WARNING: invalid UPDATE_CHECK_INTERVAL '$interval', using 86400."
                interval=86400
                ;;
            esac
            if [ "$interval" = "0" ]; then
                log "Periodic refresh disabled (UPDATE_CHECK_INTERVAL=0)."
            else
                log "Background updater started (every ${interval}s)."
                while true; do
                    sleep "$interval"
                    if [ -x /usr/local/bin/update-data ]; then
                        /usr/local/bin/update-data || log "WARNING: periodic data update failed."
                    fi
                done
            fi
        fi
    ) &
fi

# Standalone stats dashboard (replaces the LuCI statistics view).
# A failing dashboard must never kill DNS, so every launcher is guarded.
# Empty STATS_UI_PORT disables it.
if [ -n "${STATS_UI_PORT:-}" ] && [ -d /usr/share/mosdns-stats ]; then
    log "Serving stats dashboard on :${STATS_UI_PORT}"
    if command -v darkhttpd >/dev/null 2>&1; then
        darkhttpd /usr/share/mosdns-stats --port "$STATS_UI_PORT" --daemon \
            || log "WARNING: failed to start stats dashboard (darkhttpd)"
    elif busybox --list 2>/dev/null | grep -qx httpd; then
        busybox httpd -p "$STATS_UI_PORT" -h /usr/share/mosdns-stats \
            || log "WARNING: failed to start stats dashboard (busybox httpd)"
    else
        log "WARNING: no static file server found, stats dashboard disabled"
    fi
fi

exec /usr/bin/mosdns "$@"
