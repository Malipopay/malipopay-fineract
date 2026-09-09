#!/usr/bin/env bash
# Build the pinned Fineract image on a machine that has Docker but no JDK, and load it locally.
#
#   ./build-image-local.sh                 # builds the tag in deploy/UPSTREAM_VERSION
#   ./build-image-local.sh 1.15.0-mp.2
#
# CI does not use this. CI runs the jib task, publishes straight to Docker Hub, and needs
# neither the init script nor a Docker socket. This exists so the image can be built and
# proven without registry credentials.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
UPSTREAM="$(cat "$REPO/deploy/UPSTREAM_VERSION")"
TAG="${1:-${UPSTREAM}-mp.1}"
IMAGE="lockwoodtech/malipopay-fineract:${TAG}"
LOGDIR="${BUILD_LOG_DIR:-/tmp/fineract-build-logs}"
ARCH="${JIB_PLATFORM:-linux/$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')}"

case "$TAG" in
  "$UPSTREAM"-mp.*) ;;
  *) echo "tag ${TAG} does not match deploy/UPSTREAM_VERSION (${UPSTREAM})" >&2; exit 1 ;;
esac

mkdir -p "$LOGDIR"
cat > "$LOGDIR/build.sh" <<'INNER'
set -euo pipefail
cd /workspace
# gradle.properties asks for a 12g heap. Keep every --add-exports and --add-opens, which the
# build genuinely needs, and lower only the heap to what the container was given.
JVMARGS="-Xmx4g --add-exports jdk.compiler/com.sun.tools.javac.api=ALL-UNNAMED --add-exports jdk.compiler/com.sun.tools.javac.file=ALL-UNNAMED --add-exports jdk.compiler/com.sun.tools.javac.parser=ALL-UNNAMED --add-exports jdk.compiler/com.sun.tools.javac.tree=ALL-UNNAMED --add-exports jdk.compiler/com.sun.tools.javac.util=ALL-UNNAMED --add-exports=java.naming/com.sun.jndi.ldap=ALL-UNNAMED --add-opens=java.base/java.lang=ALL-UNNAMED --add-opens=java.base/java.lang.invoke=ALL-UNNAMED --add-opens=java.base/java.io=ALL-UNNAMED --add-opens=java.base/java.security=ALL-UNNAMED --add-opens=java.base/java.util=ALL-UNNAMED --add-opens=java.management/javax.management=ALL-UNNAMED --add-opens=java.naming/javax.naming=ALL-UNNAMED --add-opens=java.rmi/sun.rmi.transport=ALL-UNNAMED"

# Step one, and it must be its own invocation. Two tasks are named buildJavaSdk:
# fineract-client-feign's generates the OpenAPI Java client and is skippable,
# fineract-avro-schemas' generates the Avro Java classes fineract-core compiles against and is
# not. Gradle's -x excludes by NAME across every project, so naming this task inside the
# second invocation would not save it from the exclusion.
echo "=== step 1: Avro Java sources ==="
./gradlew --no-daemon --console=plain :fineract-avro-schemas:buildJavaSdk \
  -Dorg.gradle.jvmargs="$JVMARGS" 2>&1 | tee /logs/step1.log

echo "=== step 2: image ==="
# Gradle does NOT track -Djib.from.platforms as a task input, so jibBuildTar reports
# UP-TO-DATE and silently leaves the previous architecture's tar in place. A build for a
# different platform then "succeeds" and loads the wrong image. Removing the output is what
# forces the task to run.
rm -f fineract-provider/build/jib-image.tar
set +e
./gradlew --no-daemon --console=plain \
  -I /workspace/deploy/build/local-image.init.gradle \
  :fineract-provider:jibBuildTar \
  -x test -x cucumber -x buildJavaSdk \
  -Dorg.gradle.jvmargs="$JVMARGS" \
  -Djib.to.image="$IMAGE_REPO:$IMAGE_TAG" \
  -Djib.to.tags="$IMAGE_TAG" \
  -Djib.from.platforms="$JIB_ARCH" 2>&1 | tee /logs/step2.log
RC=${PIPESTATUS[0]}
if [ "$RC" -ne 0 ]; then
  echo "=== failed, cause follows ==="
  grep -A 20 "What went wrong" /logs/step2.log | head -30
  exit "$RC"
fi
ls -la fineract-provider/build/*.tar
INNER

# The tag goes in BOTH -Djib.to.image and -Djib.to.tags, and both are load bearing.
#
# The build file carries its own tag list, ["${project.version}", "latest"]. -Djib.to.tags
# replaces that list, which is what stops a build also producing :1.16.0-SNAPSHOT.
#
# But jib ALSO publishes the image reference itself, and an untagged reference defaults to
# :latest. So passing only the repository, with the tag in -Djib.to.tags, still produces a
# floating :latest beside the pinned tag. Measured, not assumed: that is exactly what
# happened on the first amd64 build, and the stray-tag check below is what caught it.
#
# Putting the tag in both makes the reference explicit and the list a single entry.
IMAGE_REPO="${IMAGE%%:*}"
IMAGE_TAG="${IMAGE##*:}"

echo "building ${IMAGE} for ${ARCH}"
docker run --rm --name fineract-build-local \
  -v "$REPO:/workspace" -v fineract-gradle-cache:/root/.gradle \
  -v "$LOGDIR:/logs" -e IMAGE_REPO="$IMAGE_REPO" -e IMAGE_TAG="$IMAGE_TAG" -e JIB_ARCH="$ARCH" \
  -w /workspace --memory "${BUILD_MEMORY:-7g}" \
  azul/zulu-openjdk:21 bash /logs/build.sh

TAR="$REPO/fineract-provider/build/jib-image.tar"
[ -f "$TAR" ] || TAR="$(ls "$REPO"/fineract-provider/build/*.tar | head -1)"
docker load -i "$TAR"
docker image inspect "$IMAGE" --format 'built {{.Id}} arch={{.Architecture}}'

# Verify rather than trust. A green build is not evidence that the image is for the platform
# that was asked for: see the note above about jibBuildTar and UP-TO-DATE.
WANT="${ARCH##*/}"
GOT="$(docker image inspect "$IMAGE" --format '{{.Architecture}}')"
if [ "$GOT" != "$WANT" ]; then
  echo "REFUSING: asked for ${WANT}, the loaded image is ${GOT}." >&2
  echo "The build almost certainly reported UP-TO-DATE and reused the previous tar." >&2
  exit 1
fi
echo "architecture confirmed: ${GOT}"
echo
# Prove the build produced exactly one tag, not a floating one alongside it.
STRAY="$(docker image ls "$IMAGE_REPO" --format '{{.Tag}}' | grep -v "^${IMAGE_TAG}$" || true)"
if [ -n "$STRAY" ]; then
  echo
  echo "WARNING: other tags exist on ${IMAGE_REPO}:"
  echo "$STRAY" | sed 's/^/  /'
  echo "Remove them before any push. A floating tag on a core banking image is the hazard"
  echo "described in deploy/docs/adr/0001-fork-and-pin-fineract.md."
fi

echo
echo "Loaded locally. It is NOT in any registry: push it, or let the CI workflow build the"
echo "multi-architecture image, before any host can pull it." 
