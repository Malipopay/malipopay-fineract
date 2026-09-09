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

   For calibration, the last upstream upgrade was not small:

   | 1.14.0 to 1.15.0 | |
   |---|---|
   | commits | 1,238 |
   | database changesets touched | 112 |
   | Java version | unchanged at 21 |

   Measured on the fork with:

   ```bash
   git diff --name-only 1.14.0...1.15.0 -- '*/db/changelog/*' | wc -l
   git rev-list --count 1.14.0..1.15.0
   ```

   112 changesets is a migration to schedule and to time on a copy of production data first,
   not something to run at the end of a working day.
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

## Building the image, and the one flag that will catch you

The build workflow runs the Avro Java generation as its own step before the image step. That
is not tidiness, it is required, and leaving it out fails with:

```
package org.apache.fineract.avro.generic.v1 does not exist
Execution failed for task ':fineract-core:compileJava'
```

Two different Gradle tasks are named `buildJavaSdk`:

| Task | What it does | Skippable |
|---|---|---|
| `:fineract-client-feign:buildJavaSdk` | Generates the OpenAPI Java client | yes |
| `:fineract-avro-schemas:buildJavaSdk` | Generates the Avro Java classes `fineract-core` compiles against | **no** |

Gradle's `-x` excludes by name across every project, so `-x buildJavaSdk` takes both. Upstream
uses that same exclusion and gets away with it because its CI builds the workspace in an
earlier action that runs `:fineract-avro-schemas:buildJavaSdk` first. A clean build without
that prior step fails. Naming the task inside the same invocation does not help either: the
exclusion still wins. It has to be a separate invocation.

This was found by running the build, not by reading the workflow, and it would have failed on
the first tag push.
