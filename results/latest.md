# tinyproxy-IP 解析探测报告

- **UTC 时间**: 2026-08-08T02:48:04Z
- **Run ID**: 31235777871
- **域名**: `pull.free.video.10010.com`
- **解析到 IP 数**: 2
- **80 开放**: 2
- **443 开放**: 2
- **http-gateway(443)**: 1
- **tls-cdn(443)**: 2
- **推荐 http_ip**: `106.225.194.35`（CDN，走 80）
- **推荐 https_ip**: `14.215.182.75`（必须是 http-gateway，不能填 DNS 解析 IP）
- **DNS 解析到的 TLS CDN（勿作 https_ip）**: `106.225.194.35`

## 重要

`pull.free.video.10010.com` 的 DNS A 记录通常是 **TLS CDN**。
TinyProxy 的 `https_first` Host 注入需要 **443 端口上的明文 HTTP 网关**。
把 CDN IP 同时填进 `http_ip` 和 `https_ip` 会导致：**HTTP✓ HTTPS✗**。

## 明细

| domain | ip | port80 | lat80(ms) | http_code | port443 | lat443(ms) | https_code | kind |
|---|---|---|---:|---|---|---:|---|---|
| pull.free.video.10010.com | 106.225.194.35 | ok | 271 | 404 | ok | 253 | 404 | tls-cdn |
| pull.free.video.10010.com | 111.32.132.35 | ok | 215 | 404 | ok | 217 | 404 | tls-cdn |
| seed-gateway | 14.215.182.75 | - | - | - | ok | 242 | - | http-gateway |

## 可直接用于 conf 的片段

```
http_ip=106.225.194.35;
http_port=80;
https_ip=14.215.182.75;
https_port=443;
```

> GitHub Actions 跑在海外机房，节点可能与国内不同；连通 ≠ 免流。
