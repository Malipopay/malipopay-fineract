#!/usr/bin/env bash
# Encrypted logical backup of both Fineract databases.
#
#   ./backup.sh uat            # nightly, from cron
#   ./backup.sh uat pre-release
#
# Dumps run inside the database container, so no PostgreSQL client is needed on the host and
# the credentials never appear in the process list of the host. Output is age-encrypted to
# the environment's public key before it leaves the machine, so the copy sitting in object
# storage is useless to anyone who obtains the bucket.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ENV_NAME="${1:?usage: backup.sh <uat|production> [label]}"
LABEL="${2:-nightly}"
resolve_env "$ENV_NAME"
need docker
decrypt_env

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT_DIR="${CBS_BACKUP_DIR:-/var/backups/malipopay-cbs}/$ENV_NAME"
install -d -m 700 "$OUT_DIR"

TENANTS_DB="$(env_value FINERACT_TENANTS_DB_NAME)"
TENANT_DB="$(env_value FINERACT_DEFAULT_TENANTDB_NAME)"
DB_USER="$(env_value FINERACT_HIKARI_USERNAME)"
RETENTION="$(env_value BACKUP_RETENTION_DAYS)"; RETENTION="${RETENTION:-30}"
REMOTE="$(env_value BACKUP_RCLONE_REMOTE)"
RECIPIENT_FILE="${AGE_DIR}/${ENV_NAME}.pub"

for db in "$TENANTS_DB" "$TENANT_DB"; do
  target="$OUT_DIR/${STAMP}-${LABEL}-${db}.dump"
  log "dumping ${db}"
  # -Fc is the custom format: compressed, and restorable table by table.
  docker exec malipopay-cbs-db pg_dump -Fc -U "$DB_USER" -d "$db" > "$target"
  [[ -s "$target" ]] || die "dump of ${db} is empty"

  if [[ -f "$RECIPIENT_FILE" ]]; then
    age --encrypt --recipients-file "$RECIPIENT_FILE" -o "${target}.age" "$target"
    rm -f "$target"
    target="${target}.age"
    log "encrypted to $(basename "$target") ($(du -h "$target" | cut -f1))"
  else
    log "WARNING: no recipient file at ${RECIPIENT_FILE}. The dump is UNENCRYPTED."
    log "WARNING: it holds every customer record and balance. Do not copy it off this host."
  fi
  chmod 600 "$target"

  if [[ -n "$REMOTE" ]]; then
    need rclone
    rclone copy "$target" "${REMOTE}/${ENV_NAME}/" --config /etc/malipopay-cbs/rclone.conf
    log "uploaded to ${REMOTE}/${ENV_NAME}/"
  fi
done

find "$OUT_DIR" -type f -mtime "+${RETENTION}" -print -delete | sed 's/^/pruned /'
log "backup complete: ${STAMP}-${LABEL}"

# A backup nobody has restored is a hope, not a backup. restore.sh into a scratch database
# is the drill; deploy/docs/runbooks/backup-restore.md says how often to run it.
