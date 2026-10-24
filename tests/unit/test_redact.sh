#!/bin/bash
# Join tokens and certificate keys never survive in the readable install log; ordinary lines are untouched.
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
tok=abcdef.0123456789abcdef; key=$(printf 'a%.0s' {1..64}); hash=$(printf '5%.0s' {1..64})

cat > "$SANDBOX/install.log" <<EOF
[upload-certs] Using certificate key:
$key
[bootstrap-token] Using token: $tok
  kubeadm join 192.0.2.10:6443 --token $tok \\
        --discovery-token-ca-cert-hash sha256:$hash \\
        --control-plane --certificate-key $key
  [ok] Kubernetes 1.35.9 control plane on 192.0.2.10:6443
  [ok] containerd 2.2.2, data in /data/oif/containerd
EOF
exec 7>>"$SANDBOX/install.log"          # a writer keeps the log open, as the install job does
redact_file "$SANDBOX/install.log"
echo "after" >&7; exec 7>&-

grep -qE "$tok|$key|$hash" "$SANDBOX/install.log" && fail "a secret survived: $(grep -E "$tok|$key" "$SANDBOX/install.log")"
grep -q "Using token: <redacted>" "$SANDBOX/install.log" || fail "token line redacted"
grep -qx "  \[ok\] Kubernetes 1.35.9 control plane on 192.0.2.10:6443" "$SANDBOX/install.log" || fail "ordinary line kept"
grep -qx "after" "$SANDBOX/install.log" || fail "an open writer still appends after redaction (same file)"
eq "$(echo "sha256:$hash" | redact)" "sha256:<redacted>" "pipe form:"
printf '  [ok] clean line\n' > "$SANDBOX/clean.log"; before=$(stat -c %y "$SANDBOX/clean.log"); sleep 0.05
redact_file "$SANDBOX/clean.log"
eq "$(stat -c %y "$SANDBOX/clean.log")" "$before" "a clean log is not rewritten (tail -f stays quiet):"
finish
