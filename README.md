# tinyproxy-IP

每日自动解析联通免流相关域名（默认 `pull.free.video.10010.com`），区分 **TLS CDN** 与 **HTTPS 注入网关**，筛选可用 `http_ip` / `https_ip`，写入 `results/`，并通过企业微信机器人推送。

仓库：<https://github.com/illria/tinyproxy-IP>

## 你为什么会 HTTP✓ HTTPS✗

截图里的典型失败：

```text
HTTP-IP:  220.205.125.35:80   → HTTP 测试可用 ✓
HTTPS-IP: 220.205.125.35:443  → HTTPS 测试可用 ✗
```

原因：

| 角色 | 应该是什么 | 错误填法 |
|------|------------|----------|
| `http_ip` | 视频 **CDN**（DNS 解析结果） | — |
| `https_ip` | **443 上跑明文 HTTP 的网关**（Host 注入入口） | 填成 CDN 的 DNS IP |

`pull.free.video.10010.com` 的 A 记录是 CDN，**能 TLS，但不能当 TinyProxy 的 https 注入出口**。  
原 conf 正确写法是：

```text
http_ip=CDN节点;          # 例如 220.205.125.35
https_ip=网关节点;        # 例如 14.215.182.75
https_first=...@pull.free.video.10010.com...
```

## 立刻可用的修复 conf

见仓库：

- `configs/公共免流_修复HTTPS.conf`
- `configs/公共免流_备选.conf`

核心两行：

```text
http_ip=220.205.125.35;
https_ip=14.215.182.75;
```

手机上把 conf 存到 `/storage/emulated/0/tiny/`，TinyProxy 重新加载后再测。

## 功能

1. 多 DNS 解析域名 A 记录  
2. 探测 TCP 80 / 443  
3. **分类** 443：`tls-cdn` vs `http-gateway`  
4. 推荐 `http_ip`（CDN）与 `https_ip`（仅 gateway）  
5. GitHub Actions 每天 09:00（上海）跑一次并推企业微信  

## 目录

```text
tinyproxy-IP/
├── .github/workflows/daily-resolve.yml
├── config/
│   ├── domains.txt
│   ├── dns_servers.txt
│   └── known_https_gateways.txt
├── configs/
├── scripts/
│   ├── resolve_and_probe.sh
│   ├── classify_ip.sh
│   └── notify_wecom.sh
└── results/
```

## 本地运行

```bash
sudo apt-get update && sudo apt-get install -y dnsutils curl netcat-openbsd
chmod +x scripts/*.sh
./scripts/resolve_and_probe.sh
```

## GitHub Secrets

| Secret | 值 |
|--------|-----|
| `WECOM_WEBHOOK_URL` | 企业微信机器人完整 webhook URL |

不要把 webhook / PAT 写进代码。

## 定时

```yaml
cron: "0 1 * * *"   # 01:00 UTC = 09:00 Asia/Shanghai
```

## 说明

- Actions 在海外，节点可能与国内不同  
- 连通 ≠ 免流  
- 定向免流伪装可能违反套餐协议，自行评估风险  

## License

MIT
