#!/usr/bin/env bash
# Release a pinned image to one environment.
#
#   ./release.sh uat lockwoodtech/malipopay-fineract:1.15.0-mp.2
#   ./release.sh uat                    # re-release whatever the env file already pins
#
# The image tag is written into the env file, so the running version is always recoverable
# from the host, and the previous tag is kept so rollback.sh has somewhere to go back to.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ENV_NAME="${1:?usage: release.sh <uat|production|local> [image]}"
NEW_IMAGE="${2:-}"
resolve_env "$ENV_NAME"
need docker; need curl

log "release to ${ENV_NAME} starting"
decrypt_env

CURRENT_IMAGE="$(env_value FINERACT_IMAGE)"
[[ -n "$CURRENT_IMAGE" ]] || die "FINERACT_IMAGE is not set in the environment file"

if [[ -n "$NEW_IMAGE" && "$NEW_IMAGE" != "$CURRENT_IMAGE" ]]; then
  case "$NEW_IMAGE" in
    *:latest|*:develop) die "refusing to deploy '${NEW_IMAGE}'. On Docker Hub apache/fineract:latest
       is the develop branch HEAD, not a release. Deploy a version tag built from this fork." ;;
    *:*) : ;;
    *)   die "image '${NEW_IMAGE}' has no tag" ;;
  esac
  log "image change: ${CURRENT_IMAGE} -> ${NEW_IMAGE}"
  install -d -m 700 "$STATE_DIR"
  printf '%s\n' "$CURRENT_IMAGE" > "$STATE_DIR/${ENV_NAME}.previous-image"
  sed -i.bak "s|^FINERACT_IMAGE=.*|FINERACT_IMAGE=${NEW_IMAGE}|" "$RUNTIME_ENV" && rm -f "${RUNTIME_ENV}.bak"
  log "the environment ciphertext still pins ${CURRENT_IMAGE}. Update deploy/env/.env.${ENV_NAME}.enc"
  log "and commit it, or the next deploy from a clean checkout will roll this change back."
else
  log "deploying the pinned image ${CURRENT_IMAGE}"
fi

DEPLOY_IMAGE="$(env_value FINERACT_IMAGE)"

# A schema migration cannot be undone. Snapshot before every release that changes the image.
if [[ -n "$NEW_IMAGE" && "$NEW_IMAGE" != "$CURRENT_IMAGE" && "$ENV_NAME" != "local" ]]; then
  log "taking a pre-release database snapshot (Liquibase migrations are forward only)"
  "$DEPLOY_DIR/scripts/backup.sh" "$ENV_NAME" "pre-release"
fi

log "pulling ${DEPLOY_IMAGE}"
compose pull
log "starting the stack"
compose up -d --remove-orphans

wait_healthy "${HEALTH_TIMEOUT:-420}"
smoke_test

log "release to ${ENV_NAME} complete: ${DEPLOY_IMAGE}"
compose ps
