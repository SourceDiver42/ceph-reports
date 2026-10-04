#!/usr/bin/env bash
# Weekly report: Ceph objects (RBD images / CephFS subvolumes) with no PV in
# Kubernetes, PVs left Released/Failed, and RBD trash contents.
#
# Two ways to reach Ceph (CEPH_MODE):
#   toolbox  kubectl exec into the Rook toolbox deployment (classic Rook).
#   client   run rbd/ceph directly in this pod against the external mons. This is
#            the path for Rook *external mode*, where no admin toolbox exists.
#
# Pools/filesystems can be listed explicitly (RBD_POOLS / CEPHFS_NAMES) or, when
# left empty with AUTO_DISCOVER=true, discovered from Ceph itself.
source /scripts/lib.sh
cd /tmp

generated=$(date -u +'%F %T UTC')

CEPH_MODE="${CEPH_MODE:-toolbox}"
AUTO_DISCOVER="${AUTO_DISCOVER:-true}"

# --- toolbox mode knobs --------------------------------------------------------
TOOLS_NS="${TOOLS_NS:-rook-ceph}"
TOOLS="${TOOLS:-deploy/rook-ceph-tools}"

# --- client mode knobs ---------------------------------------------------------
CEPH_USER="${CEPH_USER:-admin}"                       # ceph auth id or full name (client.<id>)
CEPH_KEY="${CEPH_KEY:-}"                               # key from a (Rook) secret; builds keyring at runtime
CEPH_KEYRING="${CEPH_KEYRING:-/etc/ceph/keyring}"     # mounted keyring file (used when CEPH_KEY is empty)
CEPH_MON_HOST="${CEPH_MON_HOST:-}"                    # explicit "host:port,..."; else read from CM
MON_ENDPOINTS_NS="${MON_ENDPOINTS_NS:-rook-ceph}"
MON_ENDPOINTS_CM="${MON_ENDPOINTS_CM:-rook-ceph-mon-endpoints}"

# --- shared knobs --------------------------------------------------------------
RBD_POOLS="${RBD_POOLS:-}"                   # space separated; empty + auto -> discover
CEPHFS_NAMES="${CEPHFS_NAMES:-}"             # space separated; empty + auto -> discover
CEPHFS_SVG="${CEPHFS_SVG:-csi}"              # subvolume group used by ceph-csi

fail() {
  alert_mail "${SUBJECT_PREFIX:-[ceph]} Weekly orphan report FAILED" "$1"
  echo "FATAL: $1" >&2
  exit 1
}

# setup_client builds /tmp/ceph.conf (from CEPH_MON_HOST or the Rook mon-endpoints
# ConfigMap) and arranges credentials via CEPH_ARGS: a runtime keyring from
# CEPH_KEY (reusing a Rook secret) or a mounted keyring file.
setup_client() {
  local mon_host="$CEPH_MON_HOST"
  if [ -z "$mon_host" ]; then
    local raw
    if ! raw=$(kubectl -n "$MON_ENDPOINTS_NS" get configmap "$MON_ENDPOINTS_CM" \
                 -o jsonpath='{.data.data}' 2>err.log); then
      cat err.log >&2
      fail "client mode: could not read ${MON_ENDPOINTS_NS}/${MON_ENDPOINTS_CM} to find the Ceph mons."
    fi
    # "a=1.2.3.4:6789,b=1.2.3.5:6789" -> "1.2.3.4:6789,1.2.3.5:6789"
    mon_host=$(printf '%s' "$raw" | tr ',' '\n' | sed 's/^[^=]*=//' | tr '\n' ',' | sed 's/,$//')
  fi
  [ -z "$mon_host" ] && fail "client mode: no Ceph mon hosts could be determined."
  {
    echo "[global]"
    echo "mon_host = ${mon_host}"
  } > /tmp/ceph.conf

  local entity="$CEPH_USER"
  case "$entity" in client.*) ;; *) entity="client.${entity}" ;; esac
  if [ -n "$CEPH_KEY" ]; then
    umask 077
    printf '[%s]\n\tkey = %s\n' "$entity" "$CEPH_KEY" > /tmp/keyring
    export CEPH_ARGS="--conf /tmp/ceph.conf --name ${entity} --keyring /tmp/keyring"
  else
    export CEPH_ARGS="--conf /tmp/ceph.conf --name ${entity} --keyring ${CEPH_KEYRING}"
  fi
}

case "$CEPH_MODE" in
  toolbox)
    tools() { kubectl -n "$TOOLS_NS" exec "$TOOLS" -- "$@"; }
    ;;
  client)
    setup_client
    # rbd/ceph pick up connection details from CEPH_ARGS exported above.
    tools() { "$@"; }
    ;;
  *)
    fail "Unknown CEPH_MODE='${CEPH_MODE}' (expected toolbox or client)."
    ;;
esac

# Auto-discover pools/filesystems from Ceph when not provided. Discovery failures
# are fatal (we cannot trust an empty list); an empty-but-successful result just
# means nothing of that type exists and is reported as a warning.
if [ -z "${RBD_POOLS// }" ] && [ "$AUTO_DISCOVER" = "true" ]; then
  if ! out=$(tools ceph osd pool ls detail -f json 2>err.log); then
    cat err.log >&2
    fail "auto-discover: 'ceph osd pool ls detail' failed. Set weekly.ceph.rbdPools explicitly."
  fi
  RBD_POOLS=$(printf '%s\n' "$out" \
    | jq -r '.[] | select((.application_metadata // {}) | has("rbd")) | .pool_name' \
    | tr '\n' ' ')
  [ -z "${RBD_POOLS// }" ] && echo "WARN: no RBD pools discovered." >&2
fi

if [ -z "${CEPHFS_NAMES// }" ] && [ "$AUTO_DISCOVER" = "true" ]; then
  if out=$(tools ceph fs ls -f json 2>err.log); then
    CEPHFS_NAMES=$(printf '%s\n' "$out" | jq -r '.[].name' | tr '\n' ' ')
  else
    cat err.log >&2
    echo "WARN: 'ceph fs ls' failed; skipping CephFS discovery." >&2
  fi
fi

kubectl get pv -o json > pv.json

# What Kubernetes knows about: "<pool|fs>/<image|subvolume>"
jq -r ".items[] | $CEPH_PV_FILTER
  | \"\(.spec.csi.volumeAttributes.pool // .spec.csi.volumeAttributes.fsName)/\(.spec.csi.volumeAttributes.imageName // .spec.csi.volumeAttributes.subvolumeName)\"" \
  pv.json | sort -u > k8s.txt

# What Ceph actually has. A failed listing must NOT be masked into an empty list:
# that would report everything as "not orphaned" (a false all-clear). Capture the
# listing separately from the grep/jq that filters it, and fail loudly if any
# pool/filesystem cannot be listed (known issue #4).
: > ceph.txt
for pool in $RBD_POOLS; do
  if ! out=$(tools rbd ls -p "$pool" 2>err.log); then
    cat err.log >&2
    fail "'rbd ls -p ${pool}' failed; skipping report to avoid a false all-clear."
  fi
  # grep may legitimately match nothing (empty pool) -> mask only that.
  printf '%s\n' "$out" | grep '^csi-vol-' | sed "s|^|${pool}/|" >> ceph.txt || true
done

for fs in $CEPHFS_NAMES; do
  if ! out=$(tools ceph fs subvolume ls "$fs" --group_name "$CEPHFS_SVG" --format json 2>err.log); then
    cat err.log >&2
    fail "'ceph fs subvolume ls ${fs}' failed; skipping report to avoid a false all-clear."
  fi
  printf '%s\n' "$out" | jq -r '.[].name' | sed "s|^|${fs}/|" >> ceph.txt
done

sort -u ceph.txt -o ceph.txt
comm -23 ceph.txt k8s.txt > orphans.txt

# Structured orphan data (attached as orphans.json), enriched per image.
: > orphans.ndjson
while read -r entry; do
  [ -z "$entry" ] && continue
  pool="${entry%%/*}"; img="${entry#*/}"
  if tools rbd info "$pool/$img" --format json > info.json 2>/dev/null; then
    size_bytes=$(jq -r '.size' info.json)
    created=$(jq -r '.create_timestamp // "?"' info.json)
    watchers=$(tools rbd status "$pool/$img" --format json 2>/dev/null | jq -r '.watchers|length' 2>/dev/null || echo null)
    jq -n --arg e "$entry" --arg p "$pool" --arg i "$img" --arg c "$created" \
          --argjson b "${size_bytes:-null}" --argjson w "${watchers:-null}" \
      '{entry:$e, pool:$p, image:$i, sizeBytes:$b, sizeGiB:(if $b==null then null else ($b/1073741824*100|round/100) end), created:$c, watchers:$w, kind:"rbd"}' \
      >> orphans.ndjson
  else
    jq -n --arg e "$entry" '{entry:$e, kind:"cephfs-or-unknown"}' >> orphans.ndjson
  fi
done < orphans.txt
jq -s --arg generated "$generated" '{generated:$generated, count:length, items:.}' orphans.ndjson > orphans.json

# Released/Failed PVs (text + JSON).
jq --arg generated "$generated" "
  {generated:\$generated,
   items: [ .items[] | $CEPH_PV_FILTER
     | select(.status.phase == \"Released\" or .status.phase == \"Failed\")
     | { name: .metadata.name, phase: .status.phase,
         reclaimPolicy: .spec.persistentVolumeReclaimPolicy,
         size: .spec.capacity.storage,
         claim: \"\(.spec.claimRef.namespace // \"?\")/\(.spec.claimRef.name // \"?\")\",
         ceph: \"\(.spec.csi.volumeAttributes.pool // .spec.csi.volumeAttributes.fsName // \"?\")/\(.spec.csi.volumeAttributes.imageName // .spec.csi.volumeAttributes.subvolumeName // \"?\")\" } ],
   count: ([ .items[] | $CEPH_PV_FILTER | select(.status.phase == \"Released\" or .status.phase == \"Failed\") ] | length)}
" pv.json > released.json

n_orph=$(jq -r '.count' orphans.json)
n_rel=$(jq -r '.count' released.json)

{
  echo "Ceph orphan report"
  echo "Generated: ${generated}"
  echo "Mode: ${CEPH_MODE}"
  echo "RBD pools: ${RBD_POOLS:-<none>}"
  echo "CephFS: ${CEPHFS_NAMES:-<none>}"
  echo
  echo "== 1. Ceph volumes with no PV in Kubernetes (${n_orph}) =="
  echo "(csi-vol-* RBD images / CephFS subvolumes not referenced by any PV)"
  echo
  jq -r '.items[]
    | if .kind == "rbd"
      then "\(.entry)  size=\(.sizeGiB // "?") GiB  created=\(.created)  watchers=\(.watchers // "?")"
      else "\(.entry)  (cephfs subvolume or info unavailable)" end' orphans.json
  echo
  echo "== 2. PVs left behind (Released/Failed) (${n_rel}) =="
  echo
  jq -r '.items[] | "\(.name)  phase=\(.phase)  reclaim=\(.reclaimPolicy)  size=\(.size)  was=\(.claim)  ceph=\(.ceph)"' released.json
  echo
  echo "== 3. RBD trash =="
  echo
  for pool in $RBD_POOLS; do
    tools rbd trash ls -p "$pool" 2>/dev/null | sed "s|^|${pool}: |" || true
  done
  echo
  echo "NOTE: review before deleting. watchers>0 means a client still has the image open."
} > report.txt

send_mail "${SUBJECT_PREFIX:-[ceph]} Weekly orphan report: ${n_orph} orphaned, ${n_rel} released PVs" \
  report.txt orphans.json released.json
