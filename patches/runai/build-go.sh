#!/bin/sh
# Builds one Go component of Run:ai with oif's patches and packages it as an image tarball: the stock image with the
# patched binary on top. Runs inside the pinned Go image as a Kubernetes Job (installer stage runai-patches); needs no
# Docker and no registry.
#   env: COMPONENT SRC_DIR BINARY TEST_PKGS RUNAI_VERSION RUNAI_SOURCE_SHA256 CRANE_VERSION CRANE_SHA256 BASE_IMAGE NEW_IMAGE
#   mounts: /patches (read), /out (write)
set -eu
cd /tmp
echo "== source run-ai $RUNAI_VERSION"
curl -fsSL -o src.tgz "https://codeload.github.com/dsx-ai-factory/run-ai/tar.gz/refs/tags/$RUNAI_VERSION"
echo "$RUNAI_SOURCE_SHA256  src.tgz" | sha256sum -c -
tar -xzf src.tgz && rm src.tgz
cd "run-ai-$RUNAI_VERSION"
for p in /patches/*"$COMPONENT"*.patch; do echo "== patch ${p##*/}"; git apply -v "$p"; done
cd "$SRC_DIR"
echo "== gofmt"
for d in $TEST_PKGS; do test -z "$(gofmt -l "$d")" || { gofmt -d "$d"; exit 1; }; done
echo "== tests ($TEST_PKGS)"
go test $TEST_PKGS > /tmp/test.log 2>&1 || { tail -40 /tmp/test.log; exit 1; }
tail -3 /tmp/test.log
echo "== build"; CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -o "/tmp/layer/$BINARY" ./cmd
echo "== image $NEW_IMAGE from $BASE_IMAGE"
curl -fsSL -o /tmp/crane.tgz "https://github.com/google/go-containerregistry/releases/download/$CRANE_VERSION/go-containerregistry_Linux_x86_64.tar.gz"
echo "$CRANE_SHA256  /tmp/crane.tgz" | sha256sum -c -
tar -xzf /tmp/crane.tgz -C /tmp crane
tar -C /tmp/layer --owner=65532 --group=0 --mode=0755 -cf /tmp/layer.tar "$BINARY"
/tmp/crane append --platform linux/amd64 --base "$BASE_IMAGE" --new_layer /tmp/layer.tar --new_tag "$NEW_IMAGE" --output "/out/$COMPONENT.tar"
sha256sum "/out/$COMPONENT.tar"
echo "== done"
