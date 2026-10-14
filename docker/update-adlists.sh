#!/bin/sh
# Update ad-blocking rule files for Docker mosdns.
# Port of mosdns.uc update_adlist()/get_adlist() (no uci/ucode needed).
#
# Aggregates every AD_SOURCES entry into a single $TXT_DIR/adlist.txt which is
# consumed by the `adlist` adblock_set plugin. A single aggregate file keeps
# the mosdns config static (adblock_set requires every listed file to exist).
# Safe to run repeatedly and via `docker exec <ctr> update-adlists`.
#
# Supported sources (space separated, same semantics as LuCI ad_source):
#   geosite.dat            use locally dumped geosite category-ads-all rules
#   file:///path/to.txt     use a local file directly (mounted into the container)
#   https://...             download (basename is used as the local file name)
#
# Env:
#   ADBLOCK=0|1             master switch (default 0)
#   AD_SOURCES=""           source list, e.g. "geosite.dat https://anti-ad.net/easylist.txt"
#   AD_UPDATE_INTERVAL=604800  re-download when the local copy is older (seconds, 0 = only if missing)
#   GITHUB_PROXY=""         prefix for https://raw.githubusercontent.com/* URLs (trailing slash optional)
#   V2DAT_DIR=/usr/share/v2ray TXT_DIR=/var/lib/mosdns ADLIST_DIR=$TXT_DIR/adlist
set -eu

ADBLOCK="${ADBLOCK:-0}"
AD_SOURCES="${AD_SOURCES:-}"
AD_UPDATE_INTERVAL="${AD_UPDATE_INTERVAL:-604800}"
GITHUB_PROXY="${GITHUB_PROXY:-}"
V2DAT_DIR="${V2DAT_DIR:-/usr/share/v2ray}"
TXT_DIR="${TXT_DIR:-/var/lib/mosdns}"
ADLIST_DIR="${ADLIST_DIR:-$TXT_DIR/adlist}"
AGGREGATE="$TXT_DIR/adlist.txt"
LOCK_DIR="${LOCK_DIR:-/tmp/mosdns-ad-update.lock}"

log() { printf '%s\n' "$*"; }

mkdir -p "$TXT_DIR" "$ADLIST_DIR"

# Disabled: keep a valid (empty) aggregate so the adlist plugin stays quiet.
if [ "$ADBLOCK" != "1" ]; then
    tmp_none="$(mktemp "$TXT_DIR/.adlist.XXXXXX")"
    printf '# MosDNS adlist (disabled)\n' > "$tmp_none"
    mv -f "$tmp_none" "$AGGREGATE"
    exit 0
fi

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    log "Another adlist update is already in progress, skipping."
    exit 0
fi
trap 'rmdir "$LOCK_DIR"' EXIT INT TERM

if [ -n "$GITHUB_PROXY" ]; then
    case "$GITHUB_PROXY" in */) ;; *) GITHUB_PROXY="$GITHUB_PROXY/";; esac
fi

# busybox mktemp requires TEMPLATE to end with XXXXXX.
tmp_agg="$(mktemp "$TXT_DIR/.adlist.XXXXXX")"
: > "$tmp_agg"
n_src=0
n_ok=0

for url in $AD_SOURCES; do
    [ -n "$url" ] || continue
    n_src=$((n_src + 1))
    case "$url" in
        geosite.dat)
            if [ -f "$V2DAT_DIR/geosite.dat" ]; then
                if geo2txt geosite -f "$V2DAT_DIR/geosite.dat" -e category-ads-all -o "$TXT_DIR"; then
                    cat "$TXT_DIR/geosite_category-ads-all.txt" >> "$tmp_agg"
                    n_ok=$((n_ok + 1))
                else
                    log "WARNING: geo2txt failed for category-ads-all, skipping."
                fi
            else
                log "WARNING: $V2DAT_DIR/geosite.dat missing, skipping geosite.dat source."
            fi
            ;;
        file://*)
            f="${url#file://}"
            if [ -f "$f" ]; then
                cat "$f" >> "$tmp_agg"
                n_ok=$((n_ok + 1))
            else
                log "WARNING: local adlist $f not found, skipping."
            fi
            ;;
        http://*|https://*)
            name="${url##*/}"
            name="${name%%\?*}"
            [ -n "$name" ] || name="adlist.txt"
            dest="$ADLIST_DIR/$name"
            dl="$url"
            case "$url" in
                https://raw.githubusercontent.com/*)
                    [ -n "$GITHUB_PROXY" ] && dl="$GITHUB_PROXY$url"
                    ;;
            esac
            need=1
            if [ -f "$dest" ]; then
                if [ "$AD_UPDATE_INTERVAL" = "0" ]; then
                    need=0
                else
                    age=$(( $(date +%s) - $(stat -c %Y "$dest") ))
                    [ "$age" -lt "$AD_UPDATE_INTERVAL" ] && need=0
                fi
            fi
            if [ "$need" = "1" ]; then
                log "Downloading $dl"
                if curl -fsSL --connect-timeout 10 --retry 2 -o "$dest.tmp" "$dl"; then
                    mv -f "$dest.tmp" "$dest"
                else
                    log "WARNING: download failed: $url (keeping old copy if any)"
                    rm -f "$dest.tmp"
                fi
            fi
            if [ -f "$dest" ]; then
                cat "$dest" >> "$tmp_agg"
                n_ok=$((n_ok + 1))
            fi
            ;;
        *)
            log "WARNING: ignoring unsupported ad source: $url"
            ;;
    esac
done

if [ "$n_ok" -gt 0 ] || [ "$n_src" -eq 0 ] || [ ! -f "$AGGREGATE" ]; then
    mv -f "$tmp_agg" "$AGGREGATE"
else
    # Every source failed but a previous aggregate exists: keep serving it.
    rm -f "$tmp_agg"
    log "WARNING: all ad sources failed, keeping previous $AGGREGATE"
fi

log "adlist update done ($n_ok/$n_src sources active)."
