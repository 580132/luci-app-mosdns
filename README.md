# luci-app-mosdns

[MosDNS](https://github.com/IrineSistiana/mosdns) is a plug-in DNS forwarder. Users can splicing plug-ins as needed to customize their own DNS processing logic.

## Fork: Custom DDNS DNS

This fork adds a **Custom DDNS DNS** option under *Basic Setting*. When enabled, domains in the *DDNS Lists* are resolved through the dedicated *DDNS DNS server* instead of the China/Local DNS, while still using a forced 5-second TTL and bypassing the cache.

UCI options:

```uci
option custom_ddns_dns '1'
list ddns_dns 'tls://8.8.8.8'
```

## Hosts / rule file auto-reload

The `mosdns` package in this repository applies the auto-reload patch (patch 206): a 3-second file watcher is attached to `hosts`, `redirect`, `domain_set`, `ip_set`, `adblock_set` and `arbitrary` rule files.

Changes to `/etc/mosdns/rule/hosts.txt` and the other rule files take effect automatically within about 3 seconds, without restarting MosDNS. The reload is logged as:

```text
INFO hosts reloaded files {"files": ["/etc/mosdns/rule/hosts.txt"]}
```

> Note: this requires installing the `mosdns` package built from this repository. Some feed builds of `mosdns` omit this patch and only reload the service on restart.

## DNS protocol standard

**General DNS (UDP):** `119.29.29.29` **&** `udp://119.29.29.29:53`

**General DNS (TCP):** `tcp://119.29.29.29` **&** `tcp://119.29.29.29:53`

**DNS-over-TLS:** `tls://120.53.53.53` **&** `tls://120.53.53.53:853`

**DNS-over-HTTPS:** `https://120.53.53.53/dns-query`

**DNS-over-HTTPS (HTTP/3):** `h3://dns.alidns.com/dns-query`

**DNS-over-QUIC:** `quic://dns.alidns.com` **&** `doq://dns.alidns.com`

## New Data Provider: `adblock_set`

The parser supports the following common DNS-related rule formats:

- `||example.com^`: Subdomain match.
- `example.com`: Exact match.
- `|example.com|`: Exact match.
- `/regexp/`: Regular expression match.
- `*keyword*`: Keyword match.
- `@@`: Prefix for whitelisting rules.
- mosdns rules: `domain:`, `full:`, `keyword:`, `regexp:`

You can now use the new provider in your `config.yaml`:

```yaml
plugins:
  - tag: "ad_rules"
    type: adblock_set
    args:
      files:
        - "./adguard_dns.txt"
        - "./easylist.txt"

  - tag: "query_is_ad"
    type: query_matcher
    args:
      domain:
        - "provider:ad_rules"
```

--------------

## How to build

- Enter in your openwrt dir

- Openwrt official SnapShots

  * requires golang 1.25.x or latest version
  ```shell
  rm -rf feeds/packages/lang/golang
  git clone https://github.com/sbwml/packages_lang_golang -b 26.x feeds/packages/lang/golang
  ```

  ```shell
  # remove v2ray-geodata package from feeds
  rm -rf feeds/packages/net/v2ray-geodata

  git clone https://github.com/sbwml/luci-app-mosdns -b v5 package/mosdns
  git clone https://github.com/sbwml/v2ray-geodata package/v2ray-geodata
  make menuconfig # choose LUCI -> Applications -> luci-app-mosdns
  make package/mosdns/luci-app-mosdns/compile V=s
  ```

- Non-Openwrt official source

  ```shell
  # drop mosdns and v2ray-geodata packages that come with the source
  find ./ | grep Makefile | grep v2ray-geodata | xargs rm -f
  find ./ | grep Makefile | grep mosdns | xargs rm -f

  git clone https://github.com/sbwml/luci-app-mosdns -b v5 package/mosdns
  git clone https://github.com/sbwml/v2ray-geodata package/v2ray-geodata
  make menuconfig # choose LUCI -> Applications -> luci-app-mosdns
  make package/mosdns/luci-app-mosdns/compile V=s
  ```

--------------

## How to install prebuilt packages

- Login OpenWrt terminal (SSH)

- Install `curl` package
  ```shell
  # for opkg package manager (24.10)
  opkg update
  opkg install curl
  
  # for apk package manager (25.12 or latest)
  apk update
  apk add curl
  ```

- Execute install script (Multi-architecture support)
  ```shell
  sh -c "$(curl -ksS https://raw.githubusercontent.com/sbwml/luci-app-mosdns/v5/install.sh)"
  ```

  install via ghproxy:
  ```shell
  sh -c "$(curl -ksS https://raw.githubusercontent.com/sbwml/luci-app-mosdns/v5/install.sh)" _ gh_proxy="https://gh-proxy.com"
  ```

--------------

![1](https://github.com/user-attachments/assets/f92847c9-4512-4969-afdc-2d83ddf3a758)
