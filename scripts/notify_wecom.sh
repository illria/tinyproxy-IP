#!/usr/bin/env bash
# Send WeCom (企业微信) group robot markdown message.
# Usage:
#   WECOM_WEBHOOK_URL='https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=xxx' \
#     ./scripts/notify_wecom.sh [path/to/latest.md]
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPORT_MD="${1:-${ROOT_DIR}/results/latest.md}"
REPORT_JSON="${ROOT_DIR}/results/latest.json"
SNIPPET="${ROOT_DIR}/results/conf_snippet.txt"

if [[ -z "${WECOM_WEBHOOK_URL:-}" && -n "${WECOM_WEBHOOK_KEY:-}" ]]; then
  WECOM_WEBHOOK_URL="https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=${WECOM_WEBHOOK_KEY}"
fi

if [[ -z "${WECOM_WEBHOOK_URL:-}" ]]; then
  echo "ERROR: set WECOM_WEBHOOK_URL or WECOM_WEBHOOK_KEY" >&2
  exit 1
fi

if [[ ! -f "${REPORT_MD}" ]]; then
  echo "ERROR: report not found: ${REPORT_MD}" >&2
  exit 1
fi

export REPORT_JSON SNIPPET
export GITHUB_SERVER_URL="${GITHUB_SERVER_URL:-https://github.com}"
export GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-illria/tinyproxy-IP}"
export GITHUB_RUN_ID="${GITHUB_RUN_ID:-}"

PAYLOAD=$(python3 <<'PY'
import json
import os
from pathlib import Path
from datetime import datetime, timezone

report_json = Path(os.environ.get("REPORT_JSON", ""))
snippet_path = Path(os.environ.get("SNIPPET", ""))
repo = os.environ.get("GITHUB_REPOSITORY", "illria/tinyproxy-IP")
server = os.environ.get("GITHUB_SERVER_URL", "https://github.com").rstrip("/")
run_id = os.environ.get("GITHUB_RUN_ID", "")

time_utc = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
total_ips = open_80 = open_443 = gateway_n = "?"
best_http = best_https = dns_tls = "N/A"
detail_lines = []

if report_json.is_file():
    data = json.loads(report_json.read_text(encoding="utf-8"))
    summary = data.get("summary") or {}
    time_utc = data.get("time_utc") or time_utc
    total_ips = summary.get("total_ips", "?")
    open_80 = summary.get("open_80", "?")
    open_443 = summary.get("open_443", "?")
    gateway_n = summary.get("http_gateway_443", "?")
    best_http = summary.get("best_http_ip") or "N/A"
    best_https = summary.get("best_https_ip") or "N/A"
    dns_tls = summary.get("dns_tls_cdn") or "N/A"
    for it in (data.get("items") or [])[:12]:
        if not it.get("ip"):
            continue
        detail_lines.append(
            f"{it.get('domain', '')} | {it.get('ip')} | "
            f"80={it.get('port80')}({it.get('latency_ms_80')}ms,{it.get('http_code')}) | "
            f"443={it.get('port443')}({it.get('latency_ms_443')}ms,{it.get('https_code')}) | "
            f"kind={it.get('kind', it.get('note',''))}"
        )

snippet_body = snippet_path.read_text(encoding="utf-8").strip() if snippet_path.is_file() else ""
detail_block = "\n".join(detail_lines) if detail_lines else "见仓库 results/latest.md"
repo_url = f"{server}/{repo}"
run_url = f"{server}/{repo}/actions/runs/{run_id}" if run_id else ""

content = f"""## tinyproxy-IP 每日解析
> UTC: **{time_utc}**
> 仓库: [{repo}]({repo_url})

**汇总**
- IP 总数: <font color="info">{total_ips}</font>
- 80 开放: <font color="info">{open_80}</font>
- 443 开放: <font color="info">{open_443}</font>
- http-gateway: <font color="info">{gateway_n}</font>
- 推荐 http_ip(CDN): `{best_http}`
- 推荐 https_ip(网关): `{best_https}`
- DNS TLS CDN(勿作https_ip): `{dns_tls}`

**conf 片段**
```
{snippet_body}
```

**明细(最多12条)**
{detail_block}
"""
if run_url:
    content += f"\n[查看本次 Action 运行]({run_url})\n"

raw = content
while len(raw.encode("utf-8")) > 3800 and len(raw) > 100:
    raw = raw[:-80]
if raw != content:
    raw += "\n\n...(truncated)"

print(json.dumps({
    "msgtype": "markdown",
    "markdown": {"content": raw},
}, ensure_ascii=False))
PY
)

echo "==> Sending WeCom notification..."
HTTP_CODE=$(curl -sS -o /tmp/wecom_resp.json -w "%{http_code}" \
  -H "Content-Type: application/json" \
  -X POST "${WECOM_WEBHOOK_URL}" \
  -d "${PAYLOAD}")

echo "HTTP ${HTTP_CODE}"
cat /tmp/wecom_resp.json 2>/dev/null || true
echo ""

if [[ "${HTTP_CODE}" != "200" ]]; then
  echo "ERROR: WeCom webhook HTTP ${HTTP_CODE}" >&2
  exit 1
fi

python3 <<'PY'
import json
d = json.load(open("/tmp/wecom_resp.json", encoding="utf-8"))
if d.get("errcode", 0) != 0:
    raise SystemExit(f"WeCom API error: {d}")
print("WeCom notify ok")
PY
