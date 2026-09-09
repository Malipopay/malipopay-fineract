> **Note for Claude and for anyone new to this repository:** this is a fork of
> **Apache Fineract**, a Java 21 / Spring Boot / Gradle core banking platform. The
> Malipopay and Lockwood backend conventions do not apply to the upstream source tree:
> not the three-layer Express architecture, not npm, not the Mongoose entity layout.
> Follow upstream Fineract conventions there, and this file everywhere else.

# Malipopay core banking fork

Malipopay runs Apache Fineract as the system of record for customer accounts, deposits and
loans, behind the Malipopay banking middleware. This fork exists to hold the deployment
layer, not to change Fineract.

## Branch model

| Branch | What it is |
|---|---|
| `develop` | An untouched mirror of upstream. Never commit here. |
| `malipopay` | The default branch. Upstream release tag `1.15.0` plus `deploy/` and the three `malipopay-*` workflows, and nothing else. |
| `upstream/<version>` | Opened automatically when a new upstream release appears. Reviewed, then merged into `malipopay`. |

## The one rule

**Never edit a file that came from upstream.** Every upstream edit is a merge conflict on
every future upgrade, and the upgrade path for a core banking system is the thing most worth
protecting. Customisation has two supported homes, both designed by upstream so that forks
stay mergeable:

- `custom/malipopay/<domain>/<module>/` for Java modules, auto-included by the build, with
  the caveat that upstream calls custom modules a proof-of-concept feature and only the note
  services are documented as replaceable.
- `/app/plugins/*` on the container classpath, for a jar dropped in at deploy time.

If something genuinely cannot be done either way, raise it upstream before forking behaviour.

## What lives here

```
deploy/
  UPSTREAM_VERSION       the single statement of which Fineract release this branch carries
  compose/               the hardened stack; does NOT extend upstream's compose files
  env/                   the environment template and SOPS ciphertext; plaintext never
  postgres/init/         database and role creation, runs once on an empty volume
  nginx/                 vhost templates plus render.sh, which fills in the allow list
  scripts/               release, rollback, backup, restore, upgrade, bootstrap, proof
  docs/                  runbooks, decision records, the local proof record
.github/workflows/malipopay-*.yml   image build, upstream watch, deploy
```

## Two things that will catch you out

**Apache publishes no Docker image for this release.** On Docker Hub, `apache/fineract`
carries `1.12.1` and earlier, plus `latest` and `develop`, which are the same digest and
both track the develop branch HEAD. Releases 1.13.0, 1.14.0 and 1.15.0 have no image at all,
because upstream's publish workflow is triggered by branch pushes and never by a version
tag. We build our own with `malipopay-docker-build.yml` and pin it. Never deploy `latest`.

**Upstream's own compose files are not safe to run.** They load
`config/docker/env/fineract-common.env`, which turns on the `test` Spring profile, opens an
unauthenticated JDWP debugger on port 5000, sets `FINERACT_INSECURE_HTTP_CLIENT=true` and
hardcodes database passwords. Upstream marks them "FOR TESTING PURPOSES ONLY" and the README
repeats the warning. `deploy/compose/` is self-contained for exactly this reason.

## Where the rest of the design lives

The banking middleware, the balance-authority rules and the phased plan are in the Malipopay
workspace, not here. Start with `deploy/docs/adr/` for the decisions that shaped this
deployment and `deploy/docs/plans/` for what is being built on top of it.
