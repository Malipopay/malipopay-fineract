#!/usr/bin/env bash
# Shared helpers. Sourced by every script in this directory.
set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_DIR="$DEPLOY_DIR/compose"
ENV_DIR="$DEPLOY_DIR/env"
STATE_DIR="${CBS_STATE_DIR:-/var/lib/malipopay-cbs}"
AGE_DIR="${CBS_AGE_DIR:-/etc/malipopay-cbs/age}"

log()  { printf '%s  %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die()  { printf '%s  ERROR: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "$1 is required but not installed"; }

# Environment name to the artefacts that belong to it.
resolve_env() {
  local env="${1:-}"
  case "$env" in
    uat)        ENC_FILE="$ENV_DIR/.env.uat.enc";        AGE_KEY="$AGE_DIR/uat.key" ;;
    production) ENC_FILE="$ENV_DIR/.env.production.enc"; AGE_KEY="$AGE_DIR/prod.key" ;;
    local)      ENC_FILE="";                             AGE_KEY="" ;;
    *) die "unknown environment '${env}'. Use: uat, production, local" ;;
  esac
  CBS_ENV="$env"
  RUNTIME_ENV="$STATE_DIR/$env.env"
}

# Decrypt the environment into a file only the deploy user can read. The plaintext lives
# under $STATE_DIR for the lifetime of the deploy and is removed on exit.
decrypt_env() {
  if [[ "$CBS_ENV" == "local" ]]; then
    RUNTIME_ENV="${CBS_LOCAL_ENV:-$ENV_DIR/.env.local}"
    [[ -f "$RUNTIME_ENV" ]] || die "local env file not found at $RUNTIME_ENV"
    return
  fi
  need sops
  [[ -f "$ENC_FILE" ]] || die "no ciphertext at $ENC_FILE"
  [[ -f "$AGE_KEY"  ]] || die "no age key at $AGE_KEY"
  install -d -m 700 "$STATE_DIR"
  ( umask 077; SOPS_AGE_KEY_FILE="$AGE_KEY" sops --decrypt --input-type dotenv \
      --output-type dotenv "$ENC_FILE" > "$RUNTIME_ENV" )
  chmod 600 "$RUNTIME_ENV"
  trap 'rm -f "$RUNTIME_ENV"' EXIT
}

# Read one value out of the decrypted env without exporting the whole file into the shell.
env_value() {
  local key="$1"
  sed -n "s/^${key}=//p" "$RUNTIME_ENV" | head -1
}

compose() {
  local files=(-f "$COMPOSE_DIR/docker-compose.yml")
  [[ "${WITH_CONSOLE:-0}" == "1" ]] && files+=(-f "$COMPOSE_DIR/docker-compose.console.yml")
  [[ "${WITH_EVENTS:-0}"  == "1" ]] && files+=(-f "$COMPOSE_DIR/docker-compose.events.yml")
  [[ "${CBS_ENV:-}" == "local" ]]   && files+=(-f "$COMPOSE_DIR/docker-compose.local.yml")
  docker compose "${files[@]}" --env-file "$RUNTIME_ENV" "$@"
}

# Wait until Fineract reports UP, or fail. A container that is "running" proves nothing:
# Liquibase can still be migrating, or the datasource can be refusing connections.
wait_healthy() {
  local timeout="${1:-300}" waited=0 status
  log "waiting for Fineract to report healthy (timeout ${timeout}s)"
  while (( waited < timeout )); do
    status="$(docker inspect -f '{{.State.Health.Status}}' malipopay-cbs-fineract 2>/dev/null || echo missing)"
    case "$status" in
      healthy) log "Fineract is healthy after ${waited}s"; return 0 ;;
      unhealthy) log "health check is failing; last 40 log lines follow"
                 docker logs --tail 40 malipopay-cbs-fineract 2>&1 | sed 's/^/    /' ;;
    esac
    sleep 5; waited=$((waited + 5))
  done
  docker logs --tail 80 malipopay-cbs-fineract 2>&1 | sed 's/^/    /'
  die "Fineract did not become healthy within ${timeout}s"
}

# Prove the API answers as the service account, not merely that the port is open.
smoke_test() {
  local port user pass base code
  port="$(env_value FINERACT_HOST_PORT)"; port="${port:-8080}"
  user="$(env_value CBS_SERVICE_USERNAME)"
  pass="$(env_value CBS_SERVICE_PASSWORD)"
  base="http://127.0.0.1:${port}/fineract-provider/api/v1"

  code="$(curl -s -o /dev/null -w '%{http_code}' \
    "http://127.0.0.1:${port}/fineract-provider/actuator/health")"
  [[ "$code" == "200" ]] || die "actuator/health returned ${code}"
  log "actuator/health 200"

  if [[ -z "$user" || -z "$pass" ]]; then
    log "CBS_SERVICE_USERNAME or CBS_SERVICE_PASSWORD is empty: skipping the authenticated"
    log "check. Create the service account (deploy/docs/runbooks/service-account.md) and"
    log "set both before the next release, or a broken credential ships unnoticed."
    return 0
  fi

  local tenant; tenant="$(env_value FINERACT_TENANT_IDENTIFIER)"
  code="$(curl -s -o /dev/null -w '%{http_code}' -u "${user}:${pass}" \
    -H "Fineract-Platform-TenantId: ${tenant}" "${base}/offices")"
  [[ "$code" == "200" ]] || die "GET /offices as the service account returned ${code}"
  log "GET /offices 200 as ${user} on tenant ${tenant}"

  # A wrong tenant header must be refused. This is the control that proves the tenant
  # context is actually enforced and the 200 above was not incidental.
  code="$(curl -s -o /dev/null -w '%{http_code}' -u "${user}:${pass}" \
    -H "Fineract-Platform-TenantId: definitely-not-a-tenant" "${base}/offices")"
  [[ "$code" != "200" ]] || die "an invalid tenant header was accepted; tenant isolation is not working"
  log "invalid tenant header refused with ${code} (control)"
}
