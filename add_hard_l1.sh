#!/usr/bin/env bash
set -euo pipefail

TRAEFIK_DIR="/opt/traefik"
DOMAIN="traefik.domain.tld"

info(){ echo "[+] $*"; }

write_file_if_changed(){
  local path="$1"
  local content="$2"

  if [[ -f "$path" ]]; then
    if cmp -s <(printf "%s" "$content") "$path"; then
      info "Unchanged: $path"
      return 0
    fi
  fi

  info "Writing: $path"
  printf "%s" "$content" > "$path"
}

info "Hardening Traefik TLS..."

# =========================
# TLS 1.3 STRICT
# =========================
TLS_OPTIONS_CONTENT=$(cat <<EOF
tls:
  options:
    strict:
      minVersion: VersionTLS13
      maxVersion: VersionTLS13
      sniStrict: true
EOF
)

write_file_if_changed "${TRAEFIK_DIR}/dynamic/tls-options.yml" "$TLS_OPTIONS_CONTENT"

# =========================
# SECURITY HEADERS
# =========================
SEC_HEADERS_CONTENT=$(cat <<EOF
http:
  middlewares:
    sec-headers:
      headers:
        sslRedirect: true
        forceSTSHeader: true
        stsSeconds: 63072000
        stsIncludeSubdomains: true
        stsPreload: true
        contentTypeNosniff: true
        frameDeny: true
        referrerPolicy: "no-referrer"
        permissionsPolicy: "geolocation=(), microphone=(), camera=()"
EOF
)

write_file_if_changed "${TRAEFIK_DIR}/dynamic/security-headers.yml" "$SEC_HEADERS_CONTENT"

# =========================
# DASHBOARD ALLOWLIST (LAN)
# =========================
ALLOWLIST_CONTENT=$(cat <<EOF
http:
  middlewares:
    dash-allowlist:
      ipAllowList:
        sourceRange:
#          - "0.0.0.0/0"
#          - "10.0.0.0/8"
#          - "172.16.0.0/12"
#          - "192.168.0.0/16"
EOF
)

write_file_if_changed "${TRAEFIK_DIR}/dynamic/dashboard-allowlist.yml" "$ALLOWLIST_CONTENT"

# =========================
# UPDATE DASHBOARD ROUTER
# =========================
DASHBOARD_CONTENT=$(cat <<EOF
http:
  routers:
    traefik-dashboard:
      rule: "Host(\`${DOMAIN}\`) && (PathPrefix(\`/api\`) || PathPrefix(\`/dashboard\`))"
      entryPoints: ["websecure"]
      service: api@internal
      middlewares:
        - dash-allowlist@file
        - sec-headers@file
      tls:
        certResolver: le
        options: strict@file
EOF
)

write_file_if_changed "${TRAEFIK_DIR}/dynamic/dashboard.yml" "$DASHBOARD_CONTENT"

# =========================
# Restart Traefik
# =========================
info "Restarting Traefik..."
docker restart traefik

info "Hardening applied."

echo
echo "Tests:"
echo "  - TLS1.3 OK:"
echo "    echo | openssl s_client -tls1_3 -servername ${DOMAIN} -connect ${DOMAIN}:443 2>/dev/null | grep Protocol"
echo
echo "  - TLS1.2 should FAIL:"
echo "    echo | openssl s_client -tls1_2 -servername ${DOMAIN} -connect ${DOMAIN}:443"
echo
echo "  - Headers:"
echo "    curl -I https://${DOMAIN}/dashboard/"
