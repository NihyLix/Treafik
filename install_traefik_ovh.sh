#!/usr/bin/env bash
set -euo pipefail

# =========================
# User config (edit here)
# =========================
TRAEFIK_DIR="/opt/traefik"
DOMAIN="traefik.domain.tld"          # <-- FQDN public (OVH)
ACME_EMAIL="admin@domain.tld"        # <-- email ACME
TZ="Europe/Paris"

# OVH endpoint: ovh-eu | ovh-ca | kimsufi-eu | soyoustart-eu
OVH_ENDPOINT="ovh-eu"

# If you already have acme.env with secrets, keep it.
# This script will NOT overwrite existing secrets by default.
OVERWRITE_SECRETS="${OVERWRITE_SECRETS:-0}"  # set 1 to overwrite acme.env

# =========================
# Helpers
# =========================
info(){ echo "[+] $*"; }
warn(){ echo "[!] $*" >&2; }
die(){ echo "[X] $*" >&2; exit 1; }

need_cmd(){
  command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"
}

write_file_if_changed(){
  local path="$1"
  local content="$2"

  if [[ -f "$path" ]]; then
    # Compare current file to desired content
    if cmp -s <(printf "%s" "$content") "$path"; then
      info "Unchanged: $path"
      return 0
    fi
  fi

  info "Writing: $path"
  install -m 0644 /dev/null "$path"
  printf "%s" "$content" > "$path"
}

# =========================
# Preconditions
# =========================
need_cmd docker
need_cmd grep
need_cmd install
need_cmd chmod

docker info >/dev/null 2>&1 || die "Docker daemon not reachable. Is it running?"

# Ensure compose plugin exists (docker compose)
docker compose version >/dev/null 2>&1 || die "docker compose plugin missing (docker-compose-plugin)."

# =========================
# Create directories
# =========================
info "Creating directories under ${TRAEFIK_DIR} ..."
install -d -m 0755 "${TRAEFIK_DIR}"
install -d -m 0755 "${TRAEFIK_DIR}/dynamic"
install -d -m 0755 "${TRAEFIK_DIR}/data"

# acme.json strict perms
if [[ ! -f "${TRAEFIK_DIR}/data/acme.json" ]]; then
  info "Creating acme.json"
  install -m 0600 /dev/null "${TRAEFIK_DIR}/data/acme.json"
else
  chmod 600 "${TRAEFIK_DIR}/data/acme.json"
  info "acme.json exists (chmod 600 enforced)"
fi

# =========================
# acme.env (secrets) - do not overwrite by default
# =========================
ACME_ENV_PATH="${TRAEFIK_DIR}/acme.env"
if [[ -f "${ACME_ENV_PATH}" && "${OVERWRITE_SECRETS}" != "1" ]]; then
  info "Keeping existing secrets file: ${ACME_ENV_PATH}"
else
  warn "Provisioning ${ACME_ENV_PATH} (OVERWRITE_SECRETS=${OVERWRITE_SECRETS})"
  cat > "${ACME_ENV_PATH}" <<EOF
# OVH DNS-01 credentials for Traefik (lego)
# Generate these in OVH API, ensure rights to manage DNS zone records.
OVH_ENDPOINT=${OVH_ENDPOINT}
OVH_APPLICATION_KEY=CHANGE_ME
OVH_APPLICATION_SECRET=CHANGE_ME
OVH_CONSUMER_KEY=CHANGE_ME
EOF
  chmod 600 "${ACME_ENV_PATH}"
fi

# =========================
# Generate configs
# =========================

TRAEFIK_YML="$(cat <<EOF
api:
  dashboard: true

log:
  level: INFO

entryPoints:
  web:
    address: ":80"
    http:
      redirections:
        entryPoint:
          to: websecure
          scheme: https
          permanent: true

  websecure:
    address: ":443"
    http:
      tls:
        certResolver: le
        domains:
          - main: "${DOMAIN}"

providers:
  docker:
    exposedByDefault: false
  file:
    directory: /dynamic
    watch: true

certificatesResolvers:
  le:
    acme:
      email: "${ACME_EMAIL}"
      storage: /data/acme.json
      dnsChallenge:
        provider: ovh
        delayBeforeCheck: 0
EOF
)"

DASHBOARD_YML="$(cat <<EOF
http:
  routers:
    traefik-dashboard:
      rule: "Host(\`${DOMAIN}\`) && (PathPrefix(\`/api\`) || PathPrefix(\`/dashboard\`))"
      entryPoints: ["websecure"]
      service: api@internal
      tls:
        certResolver: le
EOF
)"

COMPOSE_YML="$(cat <<EOF
services:
  traefik:
    image: traefik:v3.1
    container_name: traefik
    restart: unless-stopped
    environment:
      - TZ=${TZ}
    command:
      - --configFile=/etc/traefik/traefik.yml
    ports:
      - "80:80"
      - "443:443"
    env_file:
      - ./acme.env
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./traefik.yml:/etc/traefik/traefik.yml:ro
      - ./dynamic:/dynamic:ro
      - ./data:/data
EOF
)"

write_file_if_changed "${TRAEFIK_DIR}/traefik.yml" "${TRAEFIK_YML}"
write_file_if_changed "${TRAEFIK_DIR}/dynamic/dashboard.yml" "${DASHBOARD_YML}"
write_file_if_changed "${TRAEFIK_DIR}/docker-compose.yml" "${COMPOSE_YML}"

# =========================
# Basic secret sanity check (won't print secrets)
# =========================
info "Checking OVH vars presence (file format) ..."
grep -q '^OVH_ENDPOINT=' "${ACME_ENV_PATH}" || die "Missing OVH_ENDPOINT in acme.env"
grep -q '^OVH_APPLICATION_KEY=' "${ACME_ENV_PATH}" || die "Missing OVH_APPLICATION_KEY in acme.env"
grep -q '^OVH_APPLICATION_SECRET=' "${ACME_ENV_PATH}" || die "Missing OVH_APPLICATION_SECRET in acme.env"
grep -q '^OVH_CONSUMER_KEY=' "${ACME_ENV_PATH}" || die "Missing OVH_CONSUMER_KEY in acme.env"

# If still default placeholders, warn but continue
if grep -q 'CHANGE_ME' "${ACME_ENV_PATH}"; then
  warn "acme.env contains CHANGE_ME placeholders. ACME will fail until you set real OVH credentials."
fi

# =========================
# Deploy / reconcile
# =========================
info "Deploying Traefik (idempotent reconcile) ..."
cd "${TRAEFIK_DIR}"
docker compose up -d --force-recreate

info "Done."
info "Sanity checks:"
echo "  - curl (GET) local dashboard:"
echo "      curl -k -s -o /dev/null -w \"%{http_code}\n\" -H \"Host: ${DOMAIN}\" https://127.0.0.1/dashboard/"
echo "  - ACME logs (look for dnsChallenge/ovh/certificate):"
echo "      docker logs --since 10m traefik | grep -iE \"acme|dnschallenge|ovh|error|certificate\" | tail -n 200"
echo "  - served certificate (local):"
echo "      echo | openssl s_client -servername ${DOMAIN} -connect 127.0.0.1:443 2>/dev/null | openssl x509 -noout -issuer -subject -dates"
