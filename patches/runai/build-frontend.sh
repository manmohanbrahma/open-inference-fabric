#!/bin/sh
# Builds Run:ai's web UI (frontend) with oif's patches and packages it as an image tarball: the stock image with the
# patched UI files on top. Runs inside the pinned Node image as a Kubernetes Job (installer stage runai-patches).
#   env: RUNAI_VERSION RUNAI_SOURCE_SHA256 CRANE_VERSION CRANE_SHA256 BASE_IMAGE NEW_IMAGE   mounts: /patches (read), /out (write)
set -eu
cd /tmp
echo "== source run-ai $RUNAI_VERSION"
curl -fsSL -o src.tgz "https://codeload.github.com/dsx-ai-factory/run-ai/tar.gz/refs/tags/$RUNAI_VERSION"
echo "$RUNAI_SOURCE_SHA256  src.tgz" | sha256sum -c -
tar -xzf src.tgz "run-ai-$RUNAI_VERSION/control-plane/frontend" && rm src.tgz
cd "run-ai-$RUNAI_VERSION"
for p in /patches/*frontend*.patch; do echo "== patch ${p##*/}"; git apply -v "$p"; done
cd control-plane/frontend
echo "== npm ci"; npm ci --no-audit --no-fund --loglevel=error > /tmp/npm.log 2>&1 || { tail -40 /tmp/npm.log; exit 1; }
echo "== tests (icons)"
npx vitest run --environment jsdom src/common/icon.util > /tmp/test.log 2>&1 || { tail -40 /tmp/test.log; exit 1; }
grep -E "Tests|passed|failed" /tmp/test.log | tail -2
echo "== build (type check and bundle)"
NODE_OPTIONS=--max-old-space-size=8192 npm run build > /tmp/build.log 2>&1 || { tail -40 /tmp/build.log; exit 1; }
tail -2 /tmp/build.log
echo "== image $NEW_IMAGE from $BASE_IMAGE"
curl -fsSL -o crane.tgz "https://github.com/google/go-containerregistry/releases/download/$CRANE_VERSION/go-containerregistry_Linux_x86_64.tar.gz"
echo "$CRANE_SHA256  crane.tgz" | sha256sum -c -
tar -xzf crane.tgz crane
mkdir -p /tmp/layer/usr/share/nginx && cp -r dist /tmp/layer/usr/share/nginx/html
tar -C /tmp/layer --owner=0 --group=0 -cf /tmp/layer.tar usr
./crane append --platform linux/amd64 --base "$BASE_IMAGE" --new_layer /tmp/layer.tar --new_tag "$NEW_IMAGE" --output /out/frontend.tar
sha256sum /out/frontend.tar
echo "== done"
