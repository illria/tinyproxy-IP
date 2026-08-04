#!/usr/bin/env bash
# Resolve CDN domains and probe TCP 80 / 443 reachability.
# Designed for Linux / GitHub Actions (ubuntu-latest).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_DIR="${ROOT_DIR}/config"
RESULTS_DIR="${ROOT_DIR}/results"
DOMAINS_FILE="${CONFIG_DIR}/domains.txt"
DNS_FILE="${CONFIG_DIR}/dns_servers.txt"
TIMEOUT_SEC="${TIMEOUT_SEC:-3}"
RETRIES="${RETRIES:-1}"
TS_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
TS_LOCAL="$(date +%Y-%m-%d_%H%M%S 2>/dev/null || date -u +%Y-%m-%d_%H%M%S)"
RUN_ID="${GITHUB_RUN_ID:-local}"

mkdir -p "${RESULTS_DIR}"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: missing required command: $1" >&2
    exit 1
  }
}

need_cmd dig
need_cmd awk
need_cmd sort
need_cmd curl

if ! command -v timeout >/dev/null 2>&1; then
  # busybox/mac fallback: no timeout wrapper
  timeout() { shift; "$@"; }
fi

if [[ ! -f "${DOMAINS_FILE}" ]]; then
  echo "ERROR: domains file not found: ${DOMAINS_FILE}" >&2
  exit 1
fi

if [[ ! -f "${DNS_FILE}" ]]; then
  echo "ERROR: dns servers file not found: ${DNS_FILE}" >&2
  exit 1
fi

mapfile -t DOMAINS < <(grep -vE '^\s*(#|$)' "${DOMAINS_FILE}" | sed 's/\r$//' | awk '{$1=$1};1')
mapfile -t DNS_SERVERS < <(grep -vE '^\s*(#|$)' "${DNS_FILE}" | sed 's/\r$//' | awk '{$1=$1};1')

if [[ ${#DOMAINS[@]} -eq 0 ]]; then
  echo "ERROR: no domains configured" >&2
  exit 1
fi

is_ipv4() {
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

resolve_domain() {
  local domain="$1"
  local dns="$2"
  # Prefer A records; ignore CNAME chain noise
  dig +time=2 +tries=1 +short A "@${dns}" "${domain}" 2>/dev/null \
    | awk '/^([0-9]{1,3}\.){3}[0-9]{1,3}$/ {print $1}'
}

collect_ips() {
  local domain="$1"
  local ip
  local dns
  declare -A seen=()

  for dns in "${DNS_SERVERS[@]}"; do
    while IFS= read -r ip; do
      [[ -z "${ip}" ]] && continue
      is_ipv4 "${ip}" || continue
      if [[ -z "${seen[${ip}]+x}" ]]; then
        seen["${ip}"]=1
        echo "${ip}"
      fi
    done < <(resolve_domain "${domain}" "${dns}")
  done

  # Also try system resolver once
  while IFS= read -r ip; do
    [[ -z "${ip}" ]] && continue
    is_ipv4 "${ip}" || continue
    if [[ -z "${seen[${ip}]+x}" ]]; then
      seen["${ip}"]=1
      echo "${ip}"
    fi
  done < <(dig +time=2 +tries=1 +short A "${domain}" 2>/dev/null | awk '/^([0-9]{1,3}\.){3}[0-9]{1,3}$/ {print $1}')
}

# TCP connect probe: prefer nc, then bash /dev/tcp (with timeout), then curl
tcp_probe() {
  local ip="$1"
  local port="$2"
  local start end ms rc=1

  start=$(date +%s%3N 2>/dev/null || python3 -c 'import time; print(int(time.time()*1000))')

  if command -v nc >/dev/null 2>&1; then
    if timeout "${TIMEOUT_SEC}" nc -z -w "${TIMEOUT_SEC}" "${ip}" "${port}" >/dev/null 2>&1; then
      rc=0
    fi
  elif timeout "${TIMEOUT_SEC}" bash -c "echo >/dev/tcp/${ip}/${port}" >/dev/null 2>&1; then
    rc=0
  else
    # HTTP code returned means TCP connected (even 000 may mean TLS/reset after connect)
    local code
    code=$(timeout "${TIMEOUT_SEC}" curl -sS -o /dev/null -w "%{http_code}" \
      --connect-timeout "${TIMEOUT_SEC}" --max-time "${TIMEOUT_SEC}" \
      "http://${ip}:${port}/" 2>/dev/null || true)
    if [[ -n "${code}" && "${code}" != "000" ]]; then
      rc=0
    fi
  fi

  end=$(date +%s%3N 2>/dev/null || python3 -c 'import time; print(int(time.time()*1000))')
  ms=$((end - start))
  if [[ ${rc} -eq 0 ]]; then
    echo "ok ${ms}"
  else
    echo "fail ${ms}"
  fi
}

# Lightweight HTTP/HTTPS application probe with Host header
app_probe_http() {
  local ip="$1"
  local domain="$2"
  local code
  code=$(timeout "${TIMEOUT_SEC}" curl -sS -o /dev/null -w "%{http_code}" \
    --connect-timeout "${TIMEOUT_SEC}" --max-time "${TIMEOUT_SEC}" \
    -H "Host: ${domain}" \
    "http://${ip}/" 2>/dev/null || true)
  [[ -z "${code}" ]] && code="000"
  echo "${code}"
}

app_probe_https() {
  local ip="$1"
  local domain="$2"
  local code
  # -k: ignore cert mismatch (CDN IP + SNI/Host of free-video domain)
  code=$(timeout "${TIMEOUT_SEC}" curl -sS -k -o /dev/null -w "%{http_code}" \
    --connect-timeout "${TIMEOUT_SEC}" --max-time "${TIMEOUT_SEC}" \
    --resolve "${domain}:443:${ip}" \
    "https://${domain}/" 2>/dev/null || true)
  [[ -z "${code}" ]] && code="000"
  echo "${code}"
}

# Classify 443: tls-cdn (real HTTPS) vs http-gateway (plain HTTP on 443, usable as TinyProxy https_ip)
classify_443() {
  local ip="$1"
  local domain="$2"
  local connect_line ssl_kind

  connect_line=$(timeout "${TIMEOUT_SEC}" bash -c "
    exec 3<>/dev/tcp/${ip}/443 || exit 1
    printf 'CONNECT ${domain}:443 HTTP/1.1\r\nHost: ${domain}\r\n\r\n' >&3
    IFS= read -r -t ${TIMEOUT_SEC} line <&3 || true
    printf '%s' \"\$line\"
    exec 3<&-
  " 2>/dev/null | tr -d '\r' || true)

  ssl_kind=$(python3 - "${ip}" "${domain}" "${TIMEOUT_SEC}" <<'PY' 2>/dev/null || echo unknown
import socket, ssl, sys
ip, domain, t = sys.argv[1], sys.argv[2], float(sys.argv[3])
try:
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    raw = socket.create_connection((ip, 443), timeout=t)
    ss = ctx.wrap_socket(raw, server_hostname=domain)
    ss.close()
    print("tls")
except ssl.SSLError as e:
    reason = str(getattr(e, "reason", e))
    if "WRONG_VERSION" in reason:
        print("http_gateway")
    else:
        print("ssl_other")
except Exception:
    print("fail")
PY
)

  # Prefer gateway detection: HTTP reply on 443 + TLS wrong version
  if [[ "${ssl_kind}" == "http_gateway" ]]; then
    echo "http-gateway"
  elif [[ "${ssl_kind}" == "tls" ]]; then
    echo "tls-cdn"
  elif echo "${connect_line}" | grep -qE '^HTTP/'; then
    # got HTTP without successful TLS handshake
    echo "http-gateway"
  else
    echo "unknown"
  fi
}

SUMMARY_MD="${RESULTS_DIR}/latest.md"
SUMMARY_JSON="${RESULTS_DIR}/latest.json"
SUMMARY_TXT="${RESULTS_DIR}/latest.txt"
HISTORY_JSON="${RESULTS_DIR}/history_${TS_LOCAL}.json"
GOOD_HTTP="${RESULTS_DIR}/good_http_80.txt"
GOOD_HTTPS="${RESULTS_DIR}/good_https_443.txt"
GOOD_GATEWAY="${RESULTS_DIR}/good_https_gateway.txt"
TLS_CDN="${RESULTS_DIR}/tls_cdn_443.txt"
ALL_IPS="${RESULTS_DIR}/all_ips.txt"

: > "${GOOD_HTTP}"
: > "${GOOD_HTTPS}"
: > "${GOOD_GATEWAY}"
: > "${TLS_CDN}"
: > "${ALL_IPS}"

declare -a JSON_ITEMS=()
declare -a MD_ROWS=()
declare -a TXT_LINES=()

TOTAL_IPS=0
OK_80=0
OK_443=0
OK_BOTH=0
OK_GATEWAY=0
OK_TLS=0

echo "==> Start resolve & probe @ ${TS_UTC} (run=${RUN_ID})"
echo "==> Domains: ${DOMAINS[*]}"
echo "==> DNS servers: ${DNS_SERVERS[*]}"

for domain in "${DOMAINS[@]}"; do
  echo ""
  echo "---- Domain: ${domain} ----"
  mapfile -t IPS < <(collect_ips "${domain}" | sort -u)
  if [[ ${#IPS[@]} -eq 0 ]]; then
    echo "  (no A records found)"
    JSON_ITEMS+=("{\"domain\":\"${domain}\",\"ip\":\"\",\"port80\":\"none\",\"port443\":\"none\",\"http_code\":\"\",\"https_code\":\"\",\"latency_ms_80\":null,\"latency_ms_443\":null,\"note\":\"no_a_record\"}")
    MD_ROWS+=("| ${domain} | - | no A | - | - | - | - |")
    TXT_LINES+=("${domain}\tNO_A_RECORD")
    continue
  fi

  for ip in "${IPS[@]}"; do
    TOTAL_IPS=$((TOTAL_IPS + 1))
    echo "${ip}" >> "${ALL_IPS}"
    echo -n "  probe ${ip} ... "

    p80=$(tcp_probe "${ip}" 80)
    st80=$(echo "${p80}" | awk '{print $1}')
    ms80=$(echo "${p80}" | awk '{print $2}')

    p443=$(tcp_probe "${ip}" 443)
    st443=$(echo "${p443}" | awk '{print $1}')
    ms443=$(echo "${p443}" | awk '{print $2}')

    http_code="000"
    https_code="000"
    kind="n/a"
    if [[ "${st80}" == "ok" ]]; then
      OK_80=$((OK_80 + 1))
      http_code=$(app_probe_http "${ip}" "${domain}")
      echo "${ip}" >> "${GOOD_HTTP}"
    fi
    if [[ "${st443}" == "ok" ]]; then
      OK_443=$((OK_443 + 1))
      https_code=$(app_probe_https "${ip}" "${domain}")
      kind=$(classify_443 "${ip}" "${domain}")
      echo "${ip}" >> "${GOOD_HTTPS}"
      if [[ "${kind}" == "http-gateway" ]]; then
        OK_GATEWAY=$((OK_GATEWAY + 1))
        echo "${ip}" >> "${GOOD_GATEWAY}"
      elif [[ "${kind}" == "tls-cdn" ]]; then
        OK_TLS=$((OK_TLS + 1))
        echo "${ip}" >> "${TLS_CDN}"
      fi
    fi
    if [[ "${st80}" == "ok" && "${st443}" == "ok" ]]; then
      OK_BOTH=$((OK_BOTH + 1))
    fi

    echo "80=${st80}(${ms80}ms,http=${http_code}) 443=${st443}(${ms443}ms,https=${https_code},kind=${kind})"

    note="${kind}"
    if [[ "${st80}" != "ok" && "${st443}" != "ok" ]]; then
      note="both_closed"
    elif [[ "${st80}" == "ok" && "${st443}" != "ok" ]]; then
      note="http_only"
    fi

    JSON_ITEMS+=("{\"domain\":\"${domain}\",\"ip\":\"${ip}\",\"port80\":\"${st80}\",\"port443\":\"${st443}\",\"http_code\":\"${http_code}\",\"https_code\":\"${https_code}\",\"latency_ms_80\":${ms80},\"latency_ms_443\":${ms443},\"kind\":\"${kind}\",\"note\":\"${note}\"}")
    MD_ROWS+=("| ${domain} | ${ip} | ${st80} | ${ms80} | ${http_code} | ${st443} | ${ms443} | ${https_code} | ${kind} |")
    TXT_LINES+=("${domain}\t${ip}\t80=${st80}/${ms80}ms/http=${http_code}\t443=${st443}/${ms443}ms/https=${https_code}\tkind=${kind}")
  done
done

# Also probe known historical gateway seeds (not always in DNS A records)
KNOWN_GATEWAYS_FILE="${CONFIG_DIR}/known_https_gateways.txt"
if [[ -f "${KNOWN_GATEWAYS_FILE}" ]]; then
  echo ""
  echo "---- Known https gateway seeds ----"
  while IFS= read -r gip; do
    [[ -z "${gip}" || "${gip}" =~ ^# ]] && continue
    gip="${gip//$'\r'/}"
    echo -n "  seed ${gip} ... "
    p443=$(tcp_probe "${gip}" 443)
    st443=$(echo "${p443}" | awk '{print $1}')
    ms443=$(echo "${p443}" | awk '{print $2}')
    if [[ "${st443}" != "ok" ]]; then
      echo "443=fail"
      continue
    fi
    kind=$(classify_443 "${gip}" "pull.free.video.10010.com")
    echo "443=ok(${ms443}ms) kind=${kind}"
    if [[ "${kind}" == "http-gateway" ]]; then
      echo "${gip}" >> "${GOOD_GATEWAY}"
      OK_GATEWAY=$((OK_GATEWAY + 1))
      JSON_ITEMS+=("{\"domain\":\"seed-gateway\",\"ip\":\"${gip}\",\"port80\":\"n/a\",\"port443\":\"ok\",\"http_code\":\"\",\"https_code\":\"\",\"latency_ms_80\":null,\"latency_ms_443\":${ms443},\"kind\":\"http-gateway\",\"note\":\"seed\"}")
      MD_ROWS+=("| seed-gateway | ${gip} | - | - | - | ok | ${ms443} | - | http-gateway |")
      TXT_LINES+=("seed-gateway\t${gip}\t443=ok/${ms443}ms\tkind=http-gateway")
    fi
  done < "${KNOWN_GATEWAYS_FILE}"
fi

# de-dup good lists
if [[ -s "${GOOD_HTTP}" ]]; then sort -u "${GOOD_HTTP}" -o "${GOOD_HTTP}"; fi
if [[ -s "${GOOD_HTTPS}" ]]; then sort -u "${GOOD_HTTPS}" -o "${GOOD_HTTPS}"; fi
if [[ -s "${GOOD_GATEWAY}" ]]; then sort -u "${GOOD_GATEWAY}" -o "${GOOD_GATEWAY}"; fi
if [[ -s "${TLS_CDN}" ]]; then sort -u "${TLS_CDN}" -o "${TLS_CDN}"; fi
if [[ -s "${ALL_IPS}" ]]; then sort -u "${ALL_IPS}" -o "${ALL_IPS}"; fi

# http_ip: prefer open 80 CDN; https_ip: MUST be http-gateway, never bare DNS/tls-cdn
BEST_HTTP="$(head -n1 "${GOOD_HTTP}" 2>/dev/null || true)"
BEST_HTTPS="$(head -n1 "${GOOD_GATEWAY}" 2>/dev/null || true)"
BEST_TLS="$(head -n1 "${TLS_CDN}" 2>/dev/null || true)"

# Write text summary
{
  echo "tinyproxy-IP resolve report"
  echo "time_utc: ${TS_UTC}"
  echo "run_id: ${RUN_ID}"
  echo "domains: ${DOMAINS[*]}"
  echo "total_ips: ${TOTAL_IPS}"
  echo "open_80: ${OK_80}"
  echo "open_443: ${OK_443}"
  echo "open_both: ${OK_BOTH}"
  echo "http_gateway_443: ${OK_GATEWAY}"
  echo "tls_cdn_443: ${OK_TLS}"
  echo "best_http_ip(80/cdn): ${BEST_HTTP:-N/A}"
  echo "best_https_ip(gateway): ${BEST_HTTPS:-N/A}"
  echo "dns_tls_cdn(do_NOT_use_as_https_ip): ${BEST_TLS:-N/A}"
  echo ""
  echo "details:"
  for line in "${TXT_LINES[@]}"; do
    echo "  ${line}"
  done
} > "${SUMMARY_TXT}"

# Write markdown
{
  echo "# tinyproxy-IP 解析探测报告"
  echo ""
  echo "- **UTC 时间**: ${TS_UTC}"
  echo "- **Run ID**: ${RUN_ID}"
  echo "- **域名**: \`${DOMAINS[*]}\`"
  echo "- **解析到 IP 数**: ${TOTAL_IPS}"
  echo "- **80 开放**: ${OK_80}"
  echo "- **443 开放**: ${OK_443}"
  echo "- **http-gateway(443)**: ${OK_GATEWAY}"
  echo "- **tls-cdn(443)**: ${OK_TLS}"
  echo "- **推荐 http_ip**: \`${BEST_HTTP:-N/A}\`（CDN，走 80）"
  echo "- **推荐 https_ip**: \`${BEST_HTTPS:-N/A}\`（必须是 http-gateway，不能填 DNS 解析 IP）"
  echo "- **DNS 解析到的 TLS CDN（勿作 https_ip）**: \`${BEST_TLS:-N/A}\`"
  echo ""
  echo "## 重要"
  echo ""
  echo "\`pull.free.video.10010.com\` 的 DNS A 记录通常是 **TLS CDN**。"
  echo "TinyProxy 的 \`https_first\` Host 注入需要 **443 端口上的明文 HTTP 网关**。"
  echo "把 CDN IP 同时填进 \`http_ip\` 和 \`https_ip\` 会导致：**HTTP✓ HTTPS✗**。"
  echo ""
  echo "## 明细"
  echo ""
  echo "| domain | ip | port80 | lat80(ms) | http_code | port443 | lat443(ms) | https_code | kind |"
  echo "|---|---|---|---:|---|---|---:|---|---|"
  for row in "${MD_ROWS[@]}"; do
    echo "${row}"
  done
  echo ""
  echo "## 可直接用于 conf 的片段"
  echo ""
  echo '```'
  echo "http_ip=${BEST_HTTP:-请手动填写};"
  echo "http_port=80;"
  echo "https_ip=${BEST_HTTPS:-请填 http-gateway，勿用 DNS CDN IP};"
  echo "https_port=443;"
  echo '```'
  echo ""
  echo "> GitHub Actions 跑在海外机房，节点可能与国内不同；连通 ≠ 免流。"
} > "${SUMMARY_MD}"

# Write JSON
{
  echo "{"
  echo "  \"time_utc\": \"${TS_UTC}\","
  echo "  \"run_id\": \"${RUN_ID}\","
  echo "  \"domains\": ["
  local_first=1
  for d in "${DOMAINS[@]}"; do
    if [[ ${local_first} -eq 1 ]]; then local_first=0; else echo ","; fi
    printf '    "%s"' "${d}"
  done
  echo ""
  echo "  ],"
  echo "  \"summary\": {"
  echo "    \"total_ips\": ${TOTAL_IPS},"
  echo "    \"open_80\": ${OK_80},"
  echo "    \"open_443\": ${OK_443},"
  echo "    \"open_both\": ${OK_BOTH},"
  echo "    \"http_gateway_443\": ${OK_GATEWAY},"
  echo "    \"tls_cdn_443\": ${OK_TLS},"
  echo "    \"best_http_ip\": \"${BEST_HTTP:-}\","
  echo "    \"best_https_ip\": \"${BEST_HTTPS:-}\","
  echo "    \"dns_tls_cdn\": \"${BEST_TLS:-}\""
  echo "  },"
  echo "  \"items\": ["
  local_first=1
  for item in "${JSON_ITEMS[@]}"; do
    if [[ ${local_first} -eq 1 ]]; then local_first=0; else echo ","; fi
    printf '    %s' "${item}"
  done
  echo ""
  echo "  ]"
  echo "}"
} > "${SUMMARY_JSON}"

cp "${SUMMARY_JSON}" "${HISTORY_JSON}"

# conf snippet file for quick copy
CONF_SNIPPET="${RESULTS_DIR}/conf_snippet.txt"
{
  echo "http_ip=${BEST_HTTP:-};"
  echo "http_port=80;"
  echo "https_ip=${BEST_HTTPS:-};"
  echo "https_port=443;"
  echo "# kind: http_ip=CDN(80)  https_ip=http-gateway(443), NOT dns tls-cdn"
  echo "# dns_tls_cdn(do_not_use_as_https_ip)=${BEST_TLS:-}"
} > "${CONF_SNIPPET}"

echo ""
echo "==> Done"
echo "  markdown : ${SUMMARY_MD}"
echo "  json     : ${SUMMARY_JSON}"
echo "  text     : ${SUMMARY_TXT}"
echo "  good_80  : ${GOOD_HTTP}"
echo "  gateway  : ${GOOD_GATEWAY}"
echo "  tls_cdn  : ${TLS_CDN}"
echo "  snippet  : ${CONF_SNIPPET}"
echo "  best_http_ip     = ${BEST_HTTP:-N/A}"
echo "  best_https_ip    = ${BEST_HTTPS:-N/A}  (http-gateway only)"
echo "  dns_tls_cdn      = ${BEST_TLS:-N/A}  (do NOT use as https_ip)"
