#!/usr/bin/env bash
# Upgrade one environment to a newer Fineract release.
#
#   ./upgrade.sh uat lockwoodtech/malipopay-fineract:1.16.0-mp.1
#
# The order matters and is not negotiable: snapshot, then release, then verify. Liquibase
# migrates the schema on boot and the changesets carry no rollback, so the snapshot taken
# before the new image starts is the only way back.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ENV_NAME="${1:?usage: upgrade.sh <uat|production> <image>}"
IMAGE="${2:?usage: upgrade.sh <uat|production> <image>}"
resolve_env "$ENV_NAME"
need docker

log "upgrade of ${ENV_NAME} to ${IMAGE}"
log ""
log "  Checklist, and each line is a thing to have done, not to intend:"
log "   1. The same image is already running on UAT and has been exercised there."
log "   2. The upstream release notes have been read for breaking changes and for any"
log "      feature marked incomplete. 1.15.0 ships the revenue-based working capital loan"
log "      product marked not ready for production."
log "   3. The Java version in the release matches the one this fork's build workflow uses."
log "   4. A maintenance window is agreed. Migrations on a large loan portfolio are not fast."
log ""
read -r -p "Type UPGRADE ${ENV_NAME} to continue: " confirm
[[ "$confirm" == "UPGRADE ${ENV_NAME}" ]] || die "not confirmed"

decrypt_env
FROM_IMAGE="$(env_value FINERACT_IMAGE)"
log "from ${FROM_IMAGE} to ${IMAGE}"

"$DEPLOY_DIR/scripts/backup.sh" "$ENV_NAME" "pre-upgrade"
"$DEPLOY_DIR/scripts/release.sh" "$ENV_NAME" "$IMAGE"

log "upgrade complete. Verify before you call it done:"
log "  - the operations console lists offices, clients and one known account"
log "  - a deposit and a withdrawal post on a scratch account"
log "  - the close-of-business job runs to completion overnight"
log "  - the banking service reconciliation identity still balances"
