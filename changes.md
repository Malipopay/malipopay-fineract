# Changes

What shipped on the `malipopay` branch and why, newest first. Upstream Fineract's own history
is in the git log; this file covers only the Malipopay deployment layer.

## 2026-09-10 · the 1.15.0 release image, built and proven
**Why.** The first proof ran against upstream's development image, because no JDK was
available to build the release one, which left the image itself unproven.
**What changed.** `deploy/scripts/build-image-local.sh` builds and loads the pinned image in a
JDK 21 container, so it can be proven on a machine with Docker and no Java, and before any
registry credentials exist. `deploy/build/local-image.init.gradle` supplies the task wiring
upstream never added for `jibBuildTar`, from outside the source tree.
**Proven, on both architectures.** 21 passed, 0 failed on arm64, and 21 passed, 0 failed on
the 64-bit Intel image the hosts will actually run, each on a clean volume, replay included.
**Four defects fixed on the way**, each of which would have failed on first real use: the
`-x buildJavaSdk` exclusion killing the Avro generator, `jibBuildTar`'s missing dependency
wiring, a local build silently also producing a `latest` tag, and a platform change being
ignored because Gradle reported the task up to date and loaded the previous architecture.
**Related:** `deploy/docs/proof-2026-09-10-release-image.md`

## 2026-09-10 · docs(deploy): first-deploy runbook, and a measured upgrade size
**Why.** The pack could stand an environment up but nobody had written the order the steps
depend on each other in, and the upgrade runbook said "plan a window" without saying how big.
**What changed.** A first-deploy runbook from host bootstrap to the proof run, with the check
after each step that proves it worked rather than that it ran. The upgrade runbook gained a
measured figure: 1.14.0 to 1.15.0 was 1,238 commits touching 112 database changesets, which
is a migration to time against a copy of production.
**Related:** `deploy/docs/runbooks/first-deploy.md`, `deploy/docs/runbooks/upgrade.md`

## 2026-09-10 · feat(deploy): core banking age recipients and encrypted environments
**Why.** The pack shipped with placeholder age recipients, so nothing could actually be
decrypted on a host.
**What changed.** Two age keypairs generated specifically for the core banking system,
deliberately separate from the Malipopay payment service keys: a leak of a payment
environment must not decrypt the core banking database credentials. Both environment files
filled with generated 40-character secrets and committed only as ciphertext.
**Verified, not assumed.** Each file round-trips to byte-identical plaintext under its own
key; the UAT key cannot decrypt production; an existing payment service key cannot decrypt
either.
**Pending ops.** The same private keys are owed as GitHub secrets `AGE_KEY_CBS_UAT` and
`AGE_KEY_CBS_PROD`, and at `/etc/malipopay-cbs/age/` on each droplet. The Fineract service
account does not exist yet; create it with the password already in the environment file.

## 2026-09-09 · feat(deploy): Malipopay core banking deployment pack
**Why.** Fineract cannot be pulled and run at a pinned version. Docker Hub carries
`apache/fineract` only up to 1.12.1, and its floating tags are the unreleased development
branch, because upstream's publish workflow triggers on branch pushes and never on a version
tag. Separately, every upstream compose file loads an environment that enables the test
Spring profile, opens an unauthenticated debugger on port 5000 and hardcodes passwords.
**What changed.** A self-contained hardened Compose stack, SOPS environment handling, NGINX
templates whose allow list is supplied at render time and never committed, release, rollback,
backup, restore, upgrade and bootstrap scripts, an end-to-end API proof, four decision
records, five runbooks, the phase 1 middleware plan, and three workflows for building the
pinned image, watching upstream releases and deploying. The 25 inherited upstream workflows
were disabled. **No upstream source file was edited**, which is what keeps every future
release a small merge.
**Proven.** 21 checks passed with none failing, including a deposit replayed with the same
`Idempotency-Key` returning the original transaction with `x-served-from-cache: true` and no
second credit.
**Three findings folded back in.** PostgreSQL 18 moved its data directory and refuses to
start on a volume at the old path; `paymentTypeId` is mandatory on savings transactions; and
the idempotency cache stores failed responses too, so a corrected retry needs a new key.
**Related:** `deploy/docs/proof-2026-09-09.md` · **Memory:** `Malipopay/memory/project_malipopay_banking_cbs.md`
