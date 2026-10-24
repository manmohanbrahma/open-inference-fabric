#!/bin/bash
# Every recorded change is reversed by replay_manifest, newest first, leaving files as they were.
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
S=$SANDBOX/host; mkdir -p "$S/etc"

printf 'original line\n' > "$S/etc/existing.conf"
printf 'keep me\n' > "$S/etc/shared.conf"
cp "$S/etc/shared.conf" "$SANDBOX/shared.before"
printf 'a\nb\n' > "$S/etc/lines.conf"

# changes, as stages make them
put_file "$S/etc/new.conf" "new file"                       # FILE
put_file "$S/etc/existing.conf" "changed by oif"            # RESTORE
block_set "$S/etc/shared.conf" sysctl "net.ipv4.ip_forward = 1"
block_set "$S/etc/shared.conf" sysctl "net.ipv4.ip_forward = 1"   # twice: one block, one record
echo "added line" >> "$S/etc/lines.conf"; rec "LINE $S/etc/lines.conf added line"
mkdir -p "$S/data/x"; rec "DATADIR $S/data"
rec "PKG example-package"; rec "PKG example-package"

eq "$(grep -c "BLOCK $S/etc/shared.conf sysctl" "$MANIFEST")" 1 "block recorded once:"
eq "$(grep -c '^# BEGIN oif sysctl' "$S/etc/shared.conf")" 1 "block written once:"
eq "$(grep -c '^PKG ' "$MANIFEST")" 1 "package recorded once:"
eq "$(cat "$S/etc/existing.conf")" "changed by oif" "file changed:"

# plan is read-only and describes every record
before=$(cat "$MANIFEST")
out=$(tac "$MANIFEST" | describe_records)
eq "$(cat "$MANIFEST")" "$before" "describe_records is read-only:"
echo "$out" | grep -q "delete file $S/etc/new.conf" || fail "plan lists the new file"
echo "$out" | grep -q "restore $S/etc/existing.conf" || fail "plan lists the restore"

# replay: everything back as it was
teardown_example() { touch "$SANDBOX/teardown-ran"; }
register_teardown example; rec "TEARDOWN example"
replay_manifest >/dev/null
[ -e "$SANDBOX/teardown-ran" ] || fail "registered teardown ran"
[ -e "$S/etc/new.conf" ] && fail "new file removed"
eq "$(cat "$S/etc/existing.conf")" "original line" "changed file restored:"
cmp -s "$S/etc/shared.conf" "$SANDBOX/shared.before" || fail "block removed, shared file as before"
eq "$(cat "$S/etc/lines.conf")" "$(printf 'a\nb')" "added line removed:"
[ -e "$S/data" ] && fail "data folder removed"

# stages run once
n=0; stage_counter() { n=$((n + 1)); }
stage counter; stage counter
eq "$n" 1 "stage runs once:"
finish
