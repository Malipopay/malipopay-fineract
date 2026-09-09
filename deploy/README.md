# Malipopay core banking deployment

Everything Malipopay adds to Apache Fineract lives under this directory. **No file outside it
is edited.** That is the whole trick: every upstream release stays a small merge, because
there is nothing of ours in upstream's source tree to conflict with.

Start here, in order.

| If you want to | Read |
|---|---|
| Understand why any of this is shaped the way it is | `docs/adr/` (four decision records) |
| Stand up an environment from nothing | `docs/runbooks/first-deploy.md` |
| Release a new version | `docs/runbooks/release.md` |
| Take a version back out | `docs/runbooks/rollback.md` |
| Move to a newer Fineract | `docs/runbooks/upgrade.md` |
| Create the account the middleware authenticates as | `docs/runbooks/service-account.md` |
| See what was actually proven, and what was not | `docs/proof-2026-09-10-release-image.md` |
| Build the middleware that sits in front of this | `docs/plans/2026-09-09-banking-middleware-phase-1.md` |

## The shape of it

```
deploy/
  UPSTREAM_VERSION      the Fineract release this fork is pinned to. One line. Load bearing:
                        the image build refuses a tag that disagrees with it.
  compose/              the stack. Base file plus overlays for local, console and events.
  env/                  SOPS-encrypted environment per deployment. Never plaintext.
  nginx/                templates. The address allow list is supplied at render time and is
                        deliberately not in this repository.
  postgres/             the init that creates both databases and the least-privilege role.
  scripts/              bootstrap, release, rollback, backup, restore, proof, local build.
  build/                Gradle wiring supplied from outside the source tree.
  docs/                 decision records, runbooks, proof records, the middleware plan.
```

## Three things that are easy to get wrong

**The image cannot be pulled from Docker Hub.** Apache publishes `apache/fineract` only up to
1.12.1, and its `latest` and `develop` tags are the unreleased development branch. The image
this runs is built from the release tag by `.github/workflows/malipopay-docker-build.yml`, or
locally by `scripts/build-image-local.sh`. See `docs/adr/0001-fork-and-pin-fineract.md`.

**Upstream's own compose environment is not safe to deploy.** It enables the `test` Spring
profile, opens an unauthenticated debugger on port 5000, and hardcodes passwords. Upstream
says so itself. Nothing here inherits that file.

**Fineract accepts HTTP basic authentication by default**, so an instance reachable from the
public internet is a core banking system exposed to password guessing. The NGINX template
refuses to render without an allow list, and the private network is not optional.

## What is proven and what is not

`docs/proof-2026-09-10-release-image.md` records 21 checks passing against the pinned release
image on a clean database, including a deposit replayed with the same idempotency key
returning the original transaction rather than a second credit.

Not proven, because it needs a host: TLS and the address allow list, backup and restore,
close of business, and the operations console.
