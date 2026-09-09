# Malipopay core banking, operator guide

Apache Fineract, deployed by Malipopay as the system of record for customer accounts,
deposits and loans. This file is the short version. The runbooks in `deploy/docs/runbooks/`
are the long version, and they are the ones to follow when something is on fire.

## The shape of it

```
banking service (Main-Server)  ──private network──▶  NGINX 443  ──▶  fineract 127.0.0.1:8080
                                                        │                    │
                                       operations console (allow list)   postgres 18.3
```

Fineract listens on loopback only. NGINX terminates TLS and enforces an IP allow list.
Nothing reaches the core banking system from the public internet.

## Everyday commands

```bash
# What is running
docker compose -f deploy/compose/docker-compose.yml --env-file /var/lib/malipopay-cbs/uat.env ps

# Release a new pinned image (snapshots the database first, then verifies)
deploy/scripts/release.sh uat lockwoodtech/malipopay-fineract:1.15.0-mp.2

# Prove it actually works, rather than that it started
deploy/scripts/proof.sh uat

# Backup now
deploy/scripts/backup.sh uat manual

# Go back (read the header of the script first: the database does not roll back with it)
deploy/scripts/rollback.sh uat
```

## Building an image

Tag the `malipopay` branch and the workflow does the rest:

```bash
git tag mp/1.15.0-mp.2 && git push origin mp/1.15.0-mp.2
```

The tag must match `deploy/UPSTREAM_VERSION`, or the build refuses to publish. That check
exists so an image can never claim a Fineract version it was not built from.

## Upgrading

`malipopay-sync-upstream.yml` opens a pull request when Apache releases a new version. It
never merges. Read `deploy/docs/runbooks/upgrade.md` before touching it. The load-bearing
fact: Liquibase migrates the schema on boot, the changesets carry no rollback, and upstream
documents no downgrade path. The pre-upgrade snapshot is the only way back.

## Secrets

Environment files are SOPS-encrypted with age keys that exist only for the core banking
system, deliberately separate from the Malipopay payment service keys. Private keys live at
`/etc/malipopay-cbs/age/` on each host and as GitHub secrets. Plaintext env files are
gitignored and are deleted by the deploy scripts on exit.

## When something is wrong

| Symptom | Look here |
|---|---|
| Container restarts on boot | `docker logs malipopay-cbs-fineract`; usually Liquibase or the datasource |
| `503` from NGINX | Fineract is not healthy yet; migrations on a large database are slow |
| `403` from NGINX | The caller is not on the allow list. This is working correctly. |
| `400` on every call | A missing or wrong `Fineract-Platform-TenantId` header |
| A duplicate credit | Read `deploy/docs/proof-2026-09-09.md` on idempotency keys before assuming a Fineract fault |
