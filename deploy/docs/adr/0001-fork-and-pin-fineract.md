# ADR 0001: fork Apache Fineract and build our own image

**Status** accepted, 2026-09-09

## Problem

Malipopay needs a core banking system it can run, upgrade and audit. Apache Fineract is a
credible fit for accounts, deposits and loans. But it cannot simply be pulled and run: on
Docker Hub `apache/fineract` publishes no image for releases 1.13.0, 1.14.0 or 1.15.0, and
its `latest` tag is the same digest as `develop`, which is the unreleased development branch,
674 commits and two Java major versions ahead of the newest release.

## Options

**Run `apache/fineract:latest`.** Nothing to build. But it moves under you daily, it is
unreleased code, and there is no way to say which version production is running.

**Extend what exists.** Malipopay's central API already holds a working double-entry ledger.
It could grow customer accounts and loans. Rejected because it would mean building deposit
products, interest accrual, loan schedules, delinquency and close of business from scratch,
which is exactly the part Fineract has already done and had audited by other institutions.

**Fork and build a pinned image.** Fork `apache/fineract`, branch from the release tag, add
only a deployment layer, and build the image with upstream's own Jib configuration.

## Decision

Fork and build. `Malipopay/malipopay-fineract`, default branch `malipopay`, pinned at
`1.15.0`, image `lockwoodtech/malipopay-fineract:<upstream>-mp.<n>`.

Upstream source files are never edited on the fork. The whole value of this arrangement is a
cheap upgrade path, and every upstream edit is a merge conflict at every future release.
Customisation goes to `custom/malipopay/` modules or the `/app/plugins` classpath, both of
which upstream provides precisely so that forks stay mergeable.

## Reversibility

High. The fork carries no product logic. If Fineract turns out to be the wrong core, the
banking middleware's adapter interface is what has to be reimplemented, not this repository,
and this repository is deleted.

## Revisit when

Apache starts publishing release images again, which would remove the reason to build; or an
upstream release cannot be merged without editing upstream files, which would mean the
customisation has outgrown the supported extension points.
