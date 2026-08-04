#!/usr/bin/env bash
# Classify IPs: tls-cdn vs http-gateway-on-443 (usable as https_ip for TinyProxy free conf)
set -euo pipefail

TIMEOUT_SEC="${TIMEOUT_SEC:-3}"
DOMAIN="${1:-pull.free.video.10010.com}"
shift || true

if [[ $# -eq 0 ]]; then
  echo "Usage: $0 [domain] <ip> [ip...]" >&2
  echo "  or:  echo ip | $0 [domain]" >&2
  exit 1
fi

classify_one() {
  local ip="$1"
  local tcp80=0 tcp443=0 kind="dead" connect_line="" tls_line=""

  if timeout "${TIMEOUT_SEC}" bash -c "echo >/dev/tcp/${ip}/80" 2>/dev/null; then
    tcp80=1
  elif command -v nc >/dev/null 2>&1 && timeout "${TIMEOUT_SEC}" nc -z -w "${TIMEOUT_SEC}" "${ip}" 80 >/dev/null 2>&1; then
    tcp80=1
  fi

  if timeout "${TIMEOUT_SEC}" bash -c "echo >/dev/tcp/${ip}/443" 2>/dev/null; then
    tcp443=1
  elif command -v nc >/dev/null 2>&1 && timeout "${TIMEOUT_SEC}" nc -z -w "${TIMEOUT_SEC}" "${ip}" 443 >/dev/null 2>&1; then
    tcp443=1
  fi

  if [[ ${tcp443} -eq 1 ]]; then
    # Plain HTTP on 443?
    connect_line=$(timeout "${TIMEOUT_SEC}" bash -c "
      exec 3<>/dev/tcp/${ip}/443 || exit 1
      printf 'CONNECT ${DOMAIN}:443 HTTP/1.1\r\nHost: ${DOMAIN}\r\n\r\n' >&3
      IFS= read -r -t ${TIMEOUT_SEC} line <&3 || true
      printf '%s' \"\$line\"
      exec 3<&-
    " 2>/dev/null | tr -d '\r' || true)

    tls_line=$(timeout "${TIMEOUT_SEC}" curl -sS -k -o /dev/null -w "%{http_code}" \
      --connect-timeout "${TIMEOUT_SEC}" --max-time "${TIMEOUT_SEC}" \
      --resolve "${DOMAIN}:443:${ip}" "https://${DOMAIN}/" 2>/dev/null || echo "000")

    # WRONG_VERSION_NUMBER means server spoke HTTP not TLS => gateway
    if echo "${connect_line}" | grep -qE '^HTTP/'; then
      if [[ "${tls_line}" == "000" ]] || ! timeout "${TIMEOUT_SEC}" curl -sS -k -o /dev/null \
          --connect-timeout "${TIMEOUT_SEC}" --max-time "${TIMEOUT_SEC}" \
          --resolve "${DOMAIN}:443:${ip}" "https://${DOMAIN}/" >/dev/null 2>&1; then
        # try detect SSL wrong version via openssl/python quick
        if python3 - "${ip}" "${DOMAIN}" "${TIMEOUT_SEC}" <<'PY' 2>/dev/null
import socket, ssl, sys
ip, domain, t = sys.argv[1], sys.argv[2], float(sys.argv[3])
try:
    ctx = ssl.create_default_context(); ctx.check_hostname=False; ctx.verify_mode=ssl.CERT_NONE
    raw = socket.create_connection((ip,443), timeout=t)
    ss = ctx.wrap_socket(raw, server_hostname=domain)
    ss.close(); print("tls_ok")
except ssl.SSLError as e:
    print("ssl_err", getattr(e, "reason", e))
except Exception as e:
    print(type(e).__name__)
PY
        then
          :
        fi
        ssl_probe=$(python3 - "${ip}" "${DOMAIN}" "${TIMEOUT_SEC}" <<'PY' 2>/dev/null || true
import socket, ssl, sys
ip, domain, t = sys.argv[1], sys.argv[2], float(sys.argv[3])
try:
    ctx = ssl.create_default_context(); ctx.check_hostname=False; ctx.verify_mode=ssl.CERT_NONE
    raw = socket.create_connection((ip,443), timeout=t)
    ss = ctx.wrap_socket(raw, server_hostname=domain)
    ss.close(); print("tls_ok")
except ssl.SSLError as e:
    print("ssl_err:" + str(getattr(e, "reason", e)))
except Exception as e:
    print(type(e).__name__)
PY
)
        if [[ "${ssl_probe}" == tls_ok* ]]; then
          kind="tls-cdn"
        elif [[ "${ssl_probe}" == ssl_err:WRONG_VERSION_NUMBER* ]] || [[ "${ssl_probe}" == *WRONG_VERSION* ]]; then
          kind="http-gateway"
        else
          # HTTP reply on CONNECT + no good TLS => treat as gateway candidate
          if [[ "${tls_line}" =~ ^(200|301|302|403|404)$ ]]; then
            kind="tls-cdn"
          else
            kind="http-gateway"
          fi
        fi
      else
        kind="tls-cdn"
      fi
    else
      if [[ "${tls_line}" =~ ^[0-9]+$ && "${tls_line}" != "000" ]]; then
        kind="tls-cdn"
      else
        kind="unknown-443"
      fi
    fi
  elif [[ ${tcp80} -eq 1 ]]; then
    kind="http-only"
  fi

  printf '%s\t80=%s\t443=%s\tkind=%s\tconnect=%s\thttps_code=%s\n' \
    "${ip}" "${tcp80}" "${tcp443}" "${kind}" "${connect_line:0:40}" "${tls_line}"
}

if [[ $# -gt 0 ]]; then
  for ip in "$@"; do
    classify_one "${ip}"
  done
fi
