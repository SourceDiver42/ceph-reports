#!/usr/bin/env bash
# Offline fixture test for daily.sh and weekly.sh. No cluster required: kubectl,
# rbd, ceph, python3 (the mailer) are stubbed on PATH, and fixtures stand in for
# `kubectl get ... -o json`. Asserts on the captured subject, body and JSON.
#
# Usage: tests/run.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHART_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FILES="$CHART_DIR/files"
FIX="$SCRIPT_DIR/fixtures"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/scripts" "$WORK/run" "$WORK/out"

FAILED=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILED=1; }
assert_contains() { # file needle label
  if grep -qF "$2" "$1" 2>/dev/null; then pass "$3"; else fail "$3 (missing: $2)"; fi
}
assert_absent() { # file needle label
  if grep -qF "$2" "$1" 2>/dev/null; then fail "$3 (unexpected: $2)"; else pass "$3"; fi
}
assert_eq() { # actual expected label
  if [ "$1" = "$2" ]; then pass "$3"; else fail "$3 (got '$1' want '$2')"; fi
}

# --- stubs --------------------------------------------------------------------
cat > "$WORK/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
# toolbox mode: `kubectl -n ns exec target -- <cmd...>` -> run <cmd...>
seen=0; rest=()
for a in "$@"; do
  if [ "$a" = "--" ]; then seen=1; continue; fi
  [ "$seen" = "1" ] && rest+=("$a")
done
if [ "${#rest[@]}" -gt 0 ]; then exec "${rest[@]}"; fi
case "$*" in
  *"get pvc"*)  cat "$KPVC" ;;
  *"get pods"*) cat "$KPODS" ;;
  *"configmap"*) exit 1 ;;
  *"get pv"*)   cat "$KPV" ;;
  *) : ;;
esac
EOF

cat > "$WORK/bin/rbd" <<'EOF'
#!/usr/bin/env bash
sub="$1"; shift || true
case "$sub" in
  ls)
    [ "${RBD_LS_FAIL:-0}" = "1" ] && { echo "rbd: error connecting to cluster" >&2; exit 1; }
    pool=""; for a in "$@"; do pool="$a"; done
    [ "$pool" = "replicapool" ] && printf 'csi-vol-aaa\ncsi-vol-orphan\nother\n' ;;
  info)   echo '{"size":2147483648,"create_timestamp":"2026-02-02T10:00:00Z"}' ;;
  status) echo '{"watchers":[{"address":"1.2.3.4"}]}' ;;
  trash)  : ;;
esac
EOF

cat > "$WORK/bin/ceph" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"osd pool ls detail"*)   echo '[{"pool_name":"replicapool","application_metadata":{"rbd":{}}},{"pool_name":"cephfs_data","application_metadata":{"cephfs":{}}}]' ;;
  *"fs subvolume ls myfs"*) echo '[{"name":"csi-vol-bbb"}]' ;;
  *"fs ls"*)                echo '[{"name":"myfs"}]' ;;
esac
EOF

# python3 recorder stands in for the real mailer: records subject/body/attachments.
cat > "$WORK/bin/python3" <<'EOF'
#!/usr/bin/env bash
shift                       # drop send_mail.py path
printf '%s' "$1" > "$OUT/subject"
cp "$2" "$OUT/body" 2>/dev/null || true
shift 2 || true
printf '%s' "$*" > "$OUT/attach"
EOF
chmod +x "$WORK"/bin/*

# --- scripts (rewrite absolute paths to the sandbox) --------------------------
for f in lib.sh daily.sh weekly.sh send_mail.py; do cp "$FILES/$f" "$WORK/scripts/$f"; done
for f in daily.sh weekly.sh; do
  # Order matters: rewrite the /tmp/ runtime paths BEFORE inserting $WORK (which
  # itself lives under /tmp on most systems), otherwise the /tmp/ rule re-mangles
  # the $WORK prefix the other rules just inserted.
  sed -i.bak \
    -e "s|/tmp/|$WORK/run/|g" \
    -e "s|cd /tmp|cd $WORK/run|g" \
    -e "s|/scripts/|$WORK/scripts/|g" \
    "$WORK/scripts/$f"
  rm -f "$WORK/scripts/$f.bak"
done
sed -i.bak -e "s|/tmp/|$WORK/run/|g" "$WORK/scripts/lib.sh" && rm -f "$WORK/scripts/lib.sh.bak"

export PATH="$WORK/bin:$PATH"
export KPV="$FIX/pv.json" KPVC="$FIX/pvc.json" KPODS="$FIX/pods.json"
export OUT="$WORK/out"
export SMTP_URL="smtp://localhost:587" SMTP_USER="u" SMTP_PASS="p" MAIL_FROM="a@x" MAIL_TO="b@y"
export SUBJECT_PREFIX="[ceph-test]"

reset_out() { rm -f "$OUT"/* "$WORK"/run/*; }

echo "== daily.sh =="
reset_out
CLUSTER_NAME="test-cluster" bash "$WORK/scripts/daily.sh"
assert_contains "$OUT/subject" "[ceph-test] [test-cluster] Daily PVC mapping: 3 PVCs, 1 unmounted" "daily subject (counts + cluster)"
assert_contains "$OUT/attach"  "mapping.json" "daily attaches mapping.json"
assert_contains "$OUT/body" "app/data-rbd" "daily lists rbd PVC"
assert_contains "$OUT/body" "nginx:/data, sidecar:/ro (ro)" "daily shows both containers + ro"
assert_contains "$OUT/body" "myfs/csi-vol-bbb" "daily shows cephfs backing object"
assert_contains "$OUT/body" "(not mounted by any pod)" "daily flags unmounted PVC"
assert_absent  "$OUT/body" "data-nonceph" "daily ignores non-Ceph PVC"
assert_eq "$(jq -r '.total' "$WORK/run/mapping.json")" "3" "mapping.json total=3"
assert_eq "$(jq -r '.unmounted' "$WORK/run/mapping.json")" "1" "mapping.json unmounted=1"

echo "== weekly.sh (client mode, auto-discover) =="
reset_out
CEPH_MODE="client" AUTO_DISCOVER="true" CEPH_MON_HOST="1.2.3.4:6789" \
  CEPH_KEY="AQ==" CEPH_USER="csi-rbd-provisioner" \
  bash "$WORK/scripts/weekly.sh"
assert_contains "$OUT/subject" "Weekly orphan report: 1 orphaned" "weekly subject counts"
assert_contains "$OUT/attach"  "orphans.json" "weekly attaches orphans.json"
assert_absent  "$OUT/attach"  "released.json" "weekly no longer attaches released.json"
assert_eq "$(jq -r '.count' "$WORK/run/orphans.json")" "1" "orphans.json count=1"
assert_eq "$(jq -r '.items[0].entry' "$WORK/run/orphans.json")" "replicapool/csi-vol-orphan" "orphan is csi-vol-orphan"
assert_absent "$WORK/run/orphans.txt" "csi-vol-aaa" "bound image not reported as orphan"

echo "== weekly.sh (toolbox mode via kubectl exec) =="
reset_out
CEPH_MODE="toolbox" AUTO_DISCOVER="true" TOOLS_NS="rook-ceph" TOOLS="deploy/rook-ceph-tools" \
  bash "$WORK/scripts/weekly.sh"
assert_contains "$OUT/subject" "Weekly orphan report: 1 orphaned" "toolbox mode produces same result"

echo "== weekly.sh (fail-loud on rbd ls failure) =="
reset_out
set +e
CEPH_MODE="client" AUTO_DISCOVER="false" RBD_POOLS="replicapool" CEPH_MON_HOST="1.2.3.4:6789" \
  CEPH_KEY="AQ==" RBD_LS_FAIL="1" bash "$WORK/scripts/weekly.sh"
rc=$?
set -e
[ "$rc" -ne 0 ] && pass "fail-loud: non-zero exit ($rc)" || fail "fail-loud: expected non-zero exit"
assert_contains "$OUT/subject" "Weekly orphan report FAILED" "fail-loud: alert email sent"

echo
if [ "$FAILED" -eq 0 ]; then echo "ALL TESTS PASSED"; else echo "SOME TESTS FAILED"; fi
exit "$FAILED"
