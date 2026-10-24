#!/bin/sh
# Builds Run:ai's cluster-sync with oif's patches and packages it as an image tarball. Runs inside the pinned Go
# image as a Kubernetes Job (installer stage runai-patches); needs no Docker and no registry.
#   env: RUNAI_VERSION RUNAI_SOURCE_SHA256 CRANE_VERSION BASE_IMAGE NEW_IMAGE   mounts: /patches (read), /out (write)
set -eu
cd /tmp
echo "== source run-ai $RUNAI_VERSION"
curl -fsSL -o src.tgz "https://codeload.github.com/dsx-ai-factory/run-ai/tar.gz/refs/tags/$RUNAI_VERSION"
echo "$RUNAI_SOURCE_SHA256  src.tgz" | sha256sum -c -
tar -xzf src.tgz && rm src.tgz
cd "run-ai-$RUNAI_VERSION"
for p in /patches/*cluster-sync*.patch; do echo "== patch ${p##*/}"; git apply -v "$p"; done
cd runai-cluster/cluster/cluster-sync
echo "== gofmt"; test -z "$(gofmt -l pkg/handlers/parsers)" || { gofmt -d pkg/handlers/parsers; exit 1; }
echo "== tests (node parser)"
go test ./pkg/handlers/parsers/ > /tmp/test.log 2>&1 || { tail -40 /tmp/test.log; exit 1; }
tail -3 /tmp/test.log
echo "== build"; CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -o /tmp/layer/cluster-sync ./cmd
echo "== image $NEW_IMAGE from $BASE_IMAGE"
GOBIN=/tmp/bin go install "github.com/google/go-containerregistry/cmd/crane@$CRANE_VERSION"
tar -C /tmp/layer --owner=65532 --group=0 --mode=0755 -cf /tmp/layer.tar cluster-sync
/tmp/bin/crane append --platform linux/amd64 --base "$BASE_IMAGE" --new_layer /tmp/layer.tar --new_tag "$NEW_IMAGE" --output /out/cluster-sync.tar
sha256sum /out/cluster-sync.tar
echo "== done"
