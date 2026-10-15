# mosdns-docker

`mosdns` 的 Docker 构建：上游源码 + sbwml 补丁集（`adblock_set`、`stats_api`、缓存预取、日志轮转等 25 个补丁），不含 OpenWrt/LuCI。

构建时全部从上游拉取，仓库本身不 fork、不存放上游代码：

| 内容 | 来源 |
|---|---|
| mosdns 源码 | `IrineSistiana/mosdns`（tarball，sha256 校验） |
| 补丁集 + 规则占位文件 | `sbwml/luci-app-mosdns`（`PACKAGING_REF`，sparse checkout） |
| geo2txt | `sbwml/geo2txt`（源码编译） |

## 快速开始

```bash
docker compose up -d --build
```

- DNS：`53/udp` + `53/tcp`
- 统计面板：http://宿主机:8080（中文，对标 LuCI 统计页：总览/排行/即时搜索的查询日志/点击看详情）
- 原始统计 API（按需映射 9091）：`curl http://宿主机:9091/plugins/stats_collector/api/v1/stats`

GHCR 已有构建好的镜像：`ghcr.io/580132/mosdns:5`

## 常用环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `LISTEN_ADDR` / `LISTEN_PORT` | `0.0.0.0` / `53` | DNS 监听 |
| `API_LISTEN` | `0.0.0.0:9091` | stats_api 端口 |
| `LOG_LEVEL` / `LOG_FILE` | `info` / 空 | 空表示走 stderr（`docker logs`） |
| `GEO_AUTO_UPDATE` | `1` | geo 数据有更新就下载 |
| `GEOIP_TYPE` | `geoip-only-cn-private` | 精简版 geoip |
| `GITHUB_PROXY` | 空 | 如 `https://gh-proxy.com/` |
| `STATS_UI_PORT` | `8080` | 统计面板端口，置空关闭 |
| `ADBLOCK` / `AD_SOURCES` | `0` / 空 | 广告拦截开关与订阅，见下 |
| `AUTO_UPDATE` / `UPDATE_CHECK_INTERVAL` | `1` / `86400` | 后台热更新开关与周期（秒），`0` 关闭循环 |

## 广告拦截

```yaml
environment:
  ADBLOCK: "1"
  AD_SOURCES: "geosite.dat https://anti-ad.net/easylist.txt file:///etc/mosdns/rule/my-ads.txt"
```

源支持 `geosite.dat`（本地解出广告分类）、`file://`（挂载本地规则）、`https://`（下载，`raw.githubusercontent.com` 自动套代理）。更新不断 DNS（文件监听热重载），手动触发：`docker exec mosdns update-data`（geo+广告一起刷）。

## 自定义配置

挂载自己的 `config.yaml` 覆盖默认：

```yaml
volumes:
  - ./my-config.yaml:/etc/mosdns/config.yaml:ro
```

监听/日志等 env 覆盖仍会对自定义文件生效，设 `APPLY_ENV_CONFIG=0` 可关。

## 版本锁定

```bash
docker build --build-arg MOSDNS_VERSION=5.3.4 --build-arg MOSDNS_RELEASE=14 \
  --build-arg PACKAGING_REF=v5 --build-arg GEO2TXT_VERSION=1.0.0 -t mosdns .
```

`PACKAGING_REF` 可取分支、tag；CI 默认跟 `v5`。
