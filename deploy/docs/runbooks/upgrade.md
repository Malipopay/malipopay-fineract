# Runbook: upgrading Fineract

## Read this first

Liquibase migrates the schema when a new image boots. The changesets carry no rollback and
upstream documents no downgrade path: the docs use the word "downgrade" nowhere. What
upstream does have is CI that checks each pull request's migrations apply on top of the base
commit, which protects the forward direction and says nothing about the backward one.

So the practical rule is: **the pre-upgrade database snapshot is the only way back.** Going
back means restoring it, which discards every transaction written since. On a core banking
system that is a decision a person makes, with the numbers in front of them.

## Before the window

1. Read the upstream release notes end to end, not the summary. 1.15.0's notes open by
   stating that the revenue-based working capital loan product is not complete and not ready
   for production use. Features carrying that kind of warning must stay unconfigured.
2. Check the Java version in the release's own `build.gradle`. Tag 1.15.0 builds on Java 21;
   upstream `develop` has since moved to 25. If it changed, update
   `.github/workflows/malipopay-docker-build.yml` in the same pull request.
3. Count the database changesets in the diff. The sync workflow puts the number in the pull
   request body. A handful is routine. Dozens on a large loan portfolio is a window, not a
   deploy.
4. Build the image and let it run on UAT for at least one full close-of-business cycle.

## The window

```bash
deploy/scripts/upgrade.sh uat lockwoodtech/malipopay-fineract:1.16.0-mp.1
```

It snapshots, releases, waits for a real health check and runs an authenticated smoke test.
It refuses to continue at each step that fails.

## Afterwards, and none of this is optional

- `deploy/scripts/proof.sh <env>` and read the output rather than the exit code.
- Open the operations console and find one known customer, one known account and its
  balance. A migration that silently changed a balance passes every automated check.
- Let one close-of-business run complete, then read the journal entries it produced.
- Confirm the banking middleware's reconciliation identity still balances: the sum of
  customer balances in Fineract against the `Customer Funds at CBS` control account in the
  Malipopay platform books.

Until those four are done, the upgrade is deployed, not verified. Say so in those words.

## If it has gone wrong

No schema change in the release: `deploy/scripts/rollback.sh <env>` is enough.

Schema changed: stop the Fineract container first, then
`RESTORE_INTO=<live db> deploy/scripts/restore.sh <env> <the pre-upgrade dump>`, then release
the previous image. Everything written after the snapshot is gone. Before running it, work
out what that is: query the transaction count since the snapshot timestamp and tell whoever
owns those transactions.
