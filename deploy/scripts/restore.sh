#!/usr/bin/env bash
# Restore one database from a dump produced by backup.sh.
#
#   ./restore.sh uat /var/backups/malipopay-cbs/uat/20260909T2100Z-nightly-fineract_uat.dump.age
#   RESTORE_INTO=fineract_drill ./restore.sh uat <dump>    # the rehearsal, into a scratch db
#
# Restoring over a live database is destructive and irreversible. The default target is a
# scratch database precisely so that the rehearsal is the easy path and the destructive one
# has to be asked for.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ENV_NAME="${1:?usage: restore.sh <uat|production> <dump file>}"
DUMP="${2:?usage: restore.sh <uat|production> <dump file>}"
resolve_env "$ENV_NAME"
need docker
decrypt_env

[[ -f "$DUMP" ]] || die "no such dump: $DUMP"
DB_USER="$(env_value FINERACT_HIKARI_USERNAME)"
SUPER="$(env_value POSTGRES_SUPERUSER)"
TARGET_DB="${RESTORE_INTO:-fineract_restore_drill}"
LIVE_DB="$(env_value FINERACT_DEFAULT_TENANTDB_NAME)"

if [[ "$TARGET_DB" == "$LIVE_DB" || "$TARGET_DB" == "$(env_value FINERACT_TENANTS_DB_NAME)" ]]; then
  log ""
  log "  This restores over the LIVE ${ENV_NAME} database ${TARGET_DB}."
  log "  Every transaction written after $(basename "$DUMP") will be gone."
  log "  Stop the Fineract container first, or it will write into a half-restored database."
  log ""
  read -r -p "Type RESTORE ${ENV_NAME} to continue: " confirm
  [[ "$confirm" == "RESTORE ${ENV_NAME}" ]] || die "not confirmed"
  compose stop fineract
fi

PLAIN="$DUMP"
if [[ "$DUMP" == *.age ]]; then
  need age
  PLAIN="$(mktemp)"; trap 'rm -f "$PLAIN"' EXIT
  age --decrypt -i "${AGE_DIR}/${ENV_NAME}.key" -o "$PLAIN" "$DUMP"
fi

log "recreating ${TARGET_DB}"
docker exec -i malipopay-cbs-db psql -v ON_ERROR_STOP=1 -U "$SUPER" -d postgres \
  -c "DROP DATABASE IF EXISTS \"${TARGET_DB}\";" \
  -c "CREATE DATABASE \"${TARGET_DB}\" OWNER \"${DB_USER}\";"

log "restoring $(basename "$DUMP") into ${TARGET_DB}"
docker exec -i malipopay-cbs-db pg_restore -U "$SUPER" -d "$TARGET_DB" --no-owner --role="$DB_USER" < "$PLAIN"

# Report what actually landed. "pg_restore exited 0" is not proof the data is there.
log "verifying"
docker exec -i malipopay-cbs-db psql -U "$SUPER" -d "$TARGET_DB" -tAc \
  "SELECT 'tables=' || count(*) FROM information_schema.tables WHERE table_schema='public';"
docker exec -i malipopay-cbs-db psql -U "$SUPER" -d "$TARGET_DB" -tAc \
  "SELECT 'clients=' || count(*) FROM m_client;" 2>/dev/null || log "m_client not present (tenants registry dump)"
docker exec -i malipopay-cbs-db psql -U "$SUPER" -d "$TARGET_DB" -tAc \
  "SELECT 'journal_entries=' || count(*) FROM acc_gl_journal_entry;" 2>/dev/null || true

log "restore complete into ${TARGET_DB}"
