# Runbook: backup and restore

## What is backed up

Both databases: the tenants registry and the tenant's own data. `pg_dump -Fc`, run inside
the database container so no credential appears in the host's process list, age-encrypted to
the environment's public key before it leaves the machine, then copied to object storage.

Encryption is not optional. The dump holds every customer record, every balance and every
transaction. An unencrypted copy in a bucket is the whole bank in one file.

## Schedule

```cron
15 1 * * * /opt/malipopay-cbs/deploy/scripts/backup.sh uat nightly
```

`release.sh` and `upgrade.sh` also take one automatically before any image change.

## The drill, and it is the point of the whole runbook

A backup nobody has restored is a hope. Restore into a scratch database once a month and
read the row counts:

```bash
RESTORE_INTO=fineract_drill deploy/scripts/restore.sh uat \
  /var/backups/malipopay-cbs/uat/20260909T0115Z-nightly-fineract_uat.dump.age
```

The script prints the table count, the client count and the journal entry count from the
restored database. Compare them with the live system. `pg_restore` exiting zero proves the
file parsed, not that the data is there.

Record the date of each drill. If the last one is more than a month old, the recovery time
objective is a guess.

## Restoring over a live database

Only when there is no alternative, and never without knowing what will be lost.

1. Work out what is being discarded: count the transactions written after the dump's
   timestamp, and tell whoever owns them.
2. Stop the Fineract container. Restoring underneath a running application gives you a
   half-restored database and an application that has already cached the old one.
3. `RESTORE_INTO=<the live database name> deploy/scripts/restore.sh <env> <dump>`. The script
   demands a typed confirmation for this path on purpose.
4. Start Fineract and run `proof.sh`.
5. Reconcile against the Malipopay platform books before letting any customer traffic in.

## What is not covered by these backups

The age private keys and the SOPS ciphertext. Losing the key means the dumps cannot be
decrypted, which turns a complete backup into no backup at all. Store the private keys where
the organisation stores its other irreplaceable secrets, not only on the droplet.
