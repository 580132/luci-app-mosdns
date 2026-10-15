#!/bin/sh
# Update data files for Docker mosdns (port of `mosdns.uc update`).
#
# Does both jobs in one run, in order:
#   1. geo: download geoip/geosite .dat (sha256-checked) and dump .txt rules
#      with geo2txt. Dumps go to a staging dir first and are moved over
#      atomically, so mosdns picks them up through its file watcher
#      (patches 206/207) without restart and never reads a half-written file.
#   2. adlist: aggregate every AD_SOURCES entry into $TXT_DIR/adlist.txt for
#      the `adlist` adblock_set plugin (supports geosite.dat / file:// /
#      https:// sources, same semantics as LuCI ad_source).
#
# Safe to run repeatedly and via `docker exec <ctr> update-data`.
# Network failures are never fatal: previous files keep being served.
#
# Env:
#   GEO_AUTO_UPDATE=1|0        check for .dat updates when files exist (default 1;
#                              missing files are always downloaded)
#   GEOIP_TYPE=geoip-only-cn-private
#   GEOIP_URL / GEOSITE_URL    override download URLs (e.g. local mirror;
#                              GITHUB_PROXY is NOT applied to custom URLs)
#   GITHUB_PROXY=""            prefix for the default github.com URLs
#   GEOSITE_TAGS="" / GEOIP_TAGS=""  extra tags to dump, comma separated
#   V2DAT_DIR=/usr/share/v2ray TXT_DIR=/var/lib/mosdns
#   ADBLOCK=0|1                ad aggregation master switch (default 0)
#   AD_SOURCES=""              e.g. "geosite.dat https://anti-ad.net/easylist.txt"
#   UPDATE_CHECK_INTERVAL=86400  background loop cadence; doubles as the ad
#                              re-download threshold (local copy older than this
#                              gets refreshed, 0 = only download when missing)
#   ADLIST_DIR=$TXT_DIR/adlist
#
# Exit 0 when the required txt files exist afterwards, 1 otherwise.
set -eu

GEO_AUTO_UPDATE="${GEO_AUTO_UPDATE:-1}"
GEOIP_TYPE="${GEOIP_TYPE:-geoip-only-cn-private}"
GITHUB_PROXY="${GITHUB_PROXY:-}"
GEOSITE_TAGS="${GEOSITE_TAGS:-}"
GEOIP_TAGS="${GEOIP_TAGS:-}"
V2DAT_DIR="${V2DAT_DIR:-/usr/share/v2ray}"
TXT_DIR="${TXT_DIR:-/var/lib/mosdns}"
GEOIP_URL="${GEOIP_URL:-}"
GEOSITE_URL="${GEOSITE_URL:-}"
ADBLOCK="${ADBLOCK:-0}"
AD_SOURCES="${AD_SOURCES:-}"
UPDATE_CHECK_INTERVAL="${UPDATE_CHECK_INTERVAL:-86400}"
ADLIST_DIR="${ADLIST_DIR:-$TXT_DIR/adlist}"
AGGREGATE="$TXT_DIR/adlist.txt"
LOCK_DIR="${LOCK_DIR:-/tmp/mosdns-update.lock}"
STAGE=""

log() { printf '%s\n' "$*"; }

mkdir -p "$V2DAT_DIR" "$TXT_DIR" "$ADLIST_DIR"

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    log "Another update is already in progress, skipping."
    exit 0
fi
trap '[ -n "$STAGE" ] && rm -rf "$STAGE"; rmdir "$LOCK_DIR"' EXIT INT TERM

if [ -z "$GEOIP_URL" ]; then
    GEOIP_URL="https://github.com/Loyalsoldier/geoip/releases/latest/download/${GEOIP_TYPE}.dat"
fi
if [ -z "$GEOSITE_URL" ]; then
    GEOSITE_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"
fi
if [ -n "$GITHUB_PROXY" ]; then
    case "$GITHUB_PROXY" in */) ;; *) GITHUB_PROXY="$GITHUB_PROXY/";; esac
    # Proxy only applies to the default github.com URLs, not custom mirrors.
    case "$GEOIP_URL" in https://github.com/*) GEOIP_URL="$GITHUB_PROXY$GEOIP_URL";; esac
    case "$GEOSITE_URL" in https://github.com/*) GEOSITE_URL="$GITHUB_PROXY$GEOSITE_URL";; esac
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

dump_tags() { # $1=kind $2=dat $3=outdir $4...=tags (already word-split by caller)
    kind="$1"; dat="$2"; out="$3"; shift 3
    # shellcheck disable=SC2086
    geo2txt "$kind" -f "$dat" $(
        for t in $*; do printf '%s' "-e $t "; done
    ) -o "$out"
}

publish() { # $1=stagedir : atomically move results over the live files
    for f in "$1"/*.txt; do
        [ -f "$f" ] || continue
        mv -f "$f" "$TXT_DIR/${f##*/}"
    done
}

# ---------------- part 1: geo ----------------
geo_ok=1
fetch_dat "$GEOIP_URL" "$V2DAT_DIR/geoip.dat" || geo_ok=0
fetch_dat "$GEOSITE_URL" "$V2DAT_DIR/geosite.dat" || geo_ok=0

if [ -f "$V2DAT_DIR/geoip.dat" ] && [ -f "$V2DAT_DIR/geosite.dat" ]; then
    # busybox mktemp requires TEMPLATE to end with XXXXXX.
    STAGE="$(mktemp -d "$TXT_DIR/.stage.XXXXXX")"
    if dump_tags geoip "$V2DAT_DIR/geoip.dat" "$STAGE" cn \
        && dump_tags geosite "$V2DAT_DIR/geosite.dat" "$STAGE" cn 'geolocation-!cn'; then
        publish "$STAGE"
    else
        log "WARNING: base geo dump failed, keeping previous txt files."
        geo_ok=0
    fi
    if [ -n "$GEOIP_TAGS" ]; then
        tags="$(printf '%s' "$GEOIP_TAGS" | tr ',' ' ')"
        # shellcheck disable=SC2086
        if dump_tags geoip "$V2DAT_DIR/geoip.dat" "$STAGE" $tags; then
            publish "$STAGE"
        else
            log "WARNING: extra geoip dump failed, keeping previous txt files."
        fi
    fi
    if [ -n "$GEOSITE_TAGS" ]; then
        tags="$(printf '%s' "$GEOSITE_TAGS" | tr ',' ' ')"
        # shellcheck disable=SC2086
        if dump_tags geosite "$V2DAT_DIR/geosite.dat" "$STAGE" $tags; then
            publish "$STAGE"
        else
            log "WARNING: extra geosite dump failed, keeping previous txt files."
        fi
    fi
    rm -rf "$STAGE"
    STAGE=""
else
    log "WARNING: geo .dat files missing and download failed (offline?)."
    geo_ok=0
fi

# ---------------- part 2: adlist ----------------
if [ "$ADBLOCK" != "1" ]; then
    # Disabled: keep a valid (empty) aggregate so the adlist plugin stays quiet.
    tmp_none="$(mktemp "$TXT_DIR/.adlist.XXXXXX")"
    printf '# MosDNS adlist (disabled)\n' > "$tmp_none"
    mv -f "$tmp_none" "$AGGREGATE"
else
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
                    if [ "$UPDATE_CHECK_INTERVAL" = "0" ]; then
                        need=0
                    else
                        age=$(( $(date +%s) - $(stat -c %Y "$dest") ))
                        [ "$age" -lt "$UPDATE_CHECK_INTERVAL" ] && need=0
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
fi

# Usable result = the txt files the stock config references exist.
for need in "$TXT_DIR/geosite_cn.txt" "$TXT_DIR/geoip_cn.txt" "$TXT_DIR/geosite_geolocation-!cn.txt" "$AGGREGATE"; do
    if [ ! -f "$need" ]; then
        log "ERROR: required data file $need not found."
        exit 1
    fi
done
[ "$geo_ok" = "1" ] || log "WARNING: geo update incomplete, serving previous files."
exit 0
