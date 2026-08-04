# tinyproxy-IP 解析探测报告

- **UTC 时间**: 2026-08-04T19:26:26Z
- **Run ID**: local
- **域名**: `pull.free.video.10010.com`
- **解析到 IP 数**: 1
- **80 开放**: 1
- **443 开放**: 1
- **http-gateway(443)**: 1
- **tls-cdn(443)**: 1
- **推荐 http_ip**: `220.205.125.35`（CDN，走 80）
- **推荐 https_ip**: `14.215.182.75`（必须是 http-gateway，不能填 DNS 解析 IP）
- **DNS 解析到的 TLS CDN（勿作 https_ip）**: `220.205.125.35`

## 重要

`pull.free.video.10010.com` 的 DNS A 记录通常是 **TLS CDN**。
TinyProxy 的 `https_first` Host 注入需要 **443 端口上的明文 HTTP 网关**。
把 CDN IP 同时填进 `http_ip` 和 `https_ip` 会导致：**HTTP✓ HTTPS✗**。

## 明细

| domain | ip | port80 | lat80(ms) | http_code | port443 | lat443(ms) | https_code | kind |
|---|---|---|---:|---|---|---:|---|---|
| pull.free.video.10010.com | 220.205.125.35 | ok | 4 | 404 | ok | 4 | 404 | tls-cdn |
| seed-gateway | 14.215.182.75 | - | - | - | ok | 9 | - | http-gateway |

## 可直接用于 conf 的片段

```
http_ip=220.205.125.35;
http_port=80;
https_ip=14.215.182.75;
https_port=443;
```

> GitHub Actions 跑在海外机房，节点可能与国内不同；连通 ≠ 免流。
