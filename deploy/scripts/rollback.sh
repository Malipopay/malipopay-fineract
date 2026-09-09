#!/usr/bin/env bash
# Roll one environment back to the image it ran before the last release.
#
#   ./rollback.sh uat
#   ./rollback.sh uat lockwoodtech/malipopay-fineract:1.15.0-mp.1
#
# READ THIS BEFORE RUNNING IT. Rolling the image back does NOT roll the database back.
# Fineract migrates its schema with Liquibase on boot, the changesets ship no rollback, and
# upstream documents no downgrade path. If the release you are undoing migrated the schema,
# the older image will meet a newer database and may refuse to start or, worse, start and
# behave incorrectly.
#
# So there are two cases:
#   no schema change   this script is enough.
#   schema changed     restore the pre-release snapshot as well, with restore.sh. That
#                      discards every transaction written since the snapshot, which on a
#                      core banking system is a decision for a person, not a script.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ENV_NAME="${1:?usage: rollback.sh <uat|production> [image]}"
TARGET="${2:-}"
resolve_env "$ENV_NAME"
need docker

if [[ -z "$TARGET" ]]; then
  [[ -f "$STATE_DIR/${ENV_NAME}.previous-image" ]] \
    || die "no previous image recorded for ${ENV_NAME}. Pass the tag explicitly."
  TARGET="$(cat "$STATE_DIR/${ENV_NAME}.previous-image")"
fi

log "rolling ${ENV_NAME} back to ${TARGET}"
log ""
log "  Confirm first: did the release you are undoing migrate the database schema?"
log "  Check with:  docker logs malipopay-cbs-fineract 2>&1 | grep -ci liquibase"
log "  If it did, this rollback needs restore.sh as well. See the header of this script."
log ""
read -r -p "Type the environment name to continue: " confirm
[[ "$confirm" == "$ENV_NAME" ]] || die "not confirmed"

exec "$DEPLOY_DIR/scripts/release.sh" "$ENV_NAME" "$TARGET"
