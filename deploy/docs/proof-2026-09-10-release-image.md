# Proof against the 1.15.0 release image, 2026-09-10

This closes the gap left by `proof-2026-09-09.md`, which ran against upstream's development
image because no JDK was available to build the release one.

## What is different from the first run

The image is now **`lockwoodtech/malipopay-fineract:1.15.0-mp.1`**, built from upstream tag
1.15.0 with upstream's own Jib configuration, by `deploy/scripts/build-image-local.sh`.

| | |
|---|---|
| digest | `sha256:0a8163f6dcc467786d1628bdc84e6f69de79f16f20b41f108cdd8b93c3e83357` |
| architecture | arm64 |
| size | 372 MB |
| entrypoint | `java -cp @/app/jib-classpath-file org.apache.fineract.ServerApplication` |
| exposed | 8080, 8443 |

Run on a clean volume, so Liquibase created and migrated both databases from empty.

## Result

```
21 passed, 0 failed
```

Full output in `proof-2026-09-10-release-image.txt`. Every check from the first run passes
identically, including the one that matters most: the same deposit replayed with the same
`Idempotency-Key` returned the original transaction id, carried `x-served-from-cache: true`,
and left the balance at 100,000 rather than 200,000.

## Three defects this run found, all fixed

**1. The image build would have failed on its first tag push.** Two Gradle tasks are named
`buildJavaSdk`. The one in `fineract-client-feign` generates the OpenAPI Java client and is
skippable; the one in `fineract-avro-schemas` generates the Avro Java classes that
`fineract-core` compiles against, and is not. Gradle's `-x` excludes by name across every
project, so `-x buildJavaSdk` takes both, and the build dies with
`package org.apache.fineract.avro.generic.v1 does not exist`. Upstream uses the same
exclusion and gets away with it only because its CI builds the workspace in an earlier action
that runs the Avro task first. Our workflow had copied the flags without that step. It now
runs the Avro task as its own invocation, because naming it inside the same invocation does
not save it.

**2. `jibBuildTar` has no dependency wiring.** Upstream declares
`tasks.jib.dependsOn(bootJar, resolve, generateGitProperties)` and the same for
`jibDockerBuild`, and nothing for `jibBuildTar`, because upstream never builds a tar. Gradle
then refuses to run, because `jibBuildTar` reads `build/resources/main` while `resolve` writes
into it with no declared ordering. Fixed with an init script passed via `-I`, so no upstream
file is edited. CI is unaffected: it uses `jib`, which is wired.

**3. A local build also produced `:latest`.** The build file's own tag list is
`["${project.version}", "latest"]`. Passing the tag inside `-Djib.to.image` leaves that list
in place, so the load produced `1.15.0-mp.1`, `1.16.0-SNAPSHOT` and `latest` together. A
`push --all-tags` would then have published exactly the floating tag that
`adr/0001-fork-and-pin-fineract.md` exists to avoid. The repository and tag are now passed
separately, which replaces the list, and the script warns if any other tag survives.

## Still not proven, and it needs the droplet

This ran on arm64 on a developer machine. The UAT and production hosts are amd64, and the CI
workflow builds both architectures. Nothing in the run depends on the architecture, but the
amd64 image itself has not been built or started. Everything else on the list is unchanged:
NGINX and TLS, the address allow list, backup and restore, close of business, and the
operations console all need the host.
