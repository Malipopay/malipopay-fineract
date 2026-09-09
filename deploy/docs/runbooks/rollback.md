# Runbook: rolling back

## The question that decides everything

**Did the release you are undoing migrate the database schema?**

```bash
docker logs malipopay-cbs-fineract 2>&1 | grep -i 'liquibase' | grep -ci 'changeset'
```

Compare it with the same count from the previous boot, or read the changeset count in the
upgrade pull request body.

## No schema change

```bash
deploy/scripts/rollback.sh uat
```

The previous image tag was recorded by `release.sh`. The script asks for confirmation,
re-releases the old image, waits for health and runs the smoke test.

## Schema changed

The old application will meet a newer database. It may refuse to start, which is the good
case. It may start and behave incorrectly against columns it does not know about, which is
the bad one, and on a core banking system it is not a risk worth taking.

The honest options are two, and both need a person:

**Restore the pre-upgrade snapshot.** Everything written after it is discarded. Count it
first and tell whoever owns those transactions. Then follow
`backup-restore.md`, restoring over the live database, and release the previous image.

**Fix forward.** Usually better if the fault is in the application rather than the data.
Keep the new schema, ship a corrected image.

## What to do while deciding

Stop new work reaching the system rather than leaving it half-working. Turn off the banking
middleware's write path so customers get a clean refusal instead of a half-posted
transaction, and leave reads up if they are correct.

## Afterwards

Write down what happened in `deploy/docs/`, including the timestamps and what was lost. The
next person doing this at three in the morning is the audience.
