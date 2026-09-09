# ADR 0002: a self-contained compose stack rather than upstream's

**Status** accepted, 2026-09-09

## Problem

Fineract ships eighteen compose files. Reusing them looks like the obvious way to stay close
to upstream.

## What is actually in them

Every one loads `config/docker/env/fineract-common.env`, which sets:

- `SPRING_PROFILES_ACTIVE=test,diagnostics`, a profile upstream's README says explicitly must
  not be enabled in production
- a JDWP agent on port 5000, `server=y,suspend=n`, with no authentication, which is a shell
  on the core banking system for anyone who can reach the port
- `FINERACT_INSECURE_HTTP_CLIENT=true`
- database and tenant master passwords in plaintext, identical in every deployment that ever
  copied the file
- `FINERACT_DEFAULT_TENANTDB_TIMEZONE=Asia/Kolkata`, which would put Tanzanian evening
  transactions on the wrong business day

Upstream is not hiding this. Every file carries "FOR TESTING PURPOSES ONLY! NOT SUITABLE FOR
PRODUCTION USAGE!" at the top and the bottom.

## Options

**Extend upstream's files and override the dangerous values.** Fewer lines. But an override
that is removed upstream, or a new hazardous default added upstream, arrives silently at the
next merge, and the file that decides whether a debugger is open on the core banking system
is not a file to inherit.

**Write a self-contained stack.** More lines, and it has to be re-read against upstream at
each upgrade.

## Decision

Self-contained, in `deploy/compose/`. Every value is set explicitly and the file says why for
each one that differs from upstream's sample. Secrets come from a SOPS-encrypted environment
file. Fineract binds to loopback and NGINX terminates TLS in front of it.

The cost is real: at each upgrade someone must diff upstream's env files for new variables
worth adopting. That is a task in the upgrade runbook, and it is the right place for the
work, because it is a decision each time rather than a default.

## Revisit when

Upstream ships a production-intended compose or Helm chart. The deployment documentation's
Helm section currently reads "TBD".
