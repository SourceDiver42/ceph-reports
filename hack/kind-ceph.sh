#!/usr/bin/env bash
# Spin up a kind cluster + an external Ceph (single container on the kind Docker
# network) so the chart's `ceph.mode=client` path can be tested end to end.
#
#   hack/kind-ceph.sh up        # create cluster + ceph, print connection details
#   hack/kind-ceph.sh probe     # run ceph/rbd commands from inside a kind pod
#   hack/kind-ceph.sh down      # delete the cluster + ceph container
#
# Notes:
#  - Ceph runs as quay.io/ceph/demo (amd64 -> emulated on Apple Silicon, fine
#    for a tiny demo). The client-side ceph image is multi-arch (native).
#  - The mon MUST advertise an IP reachable from the kind network, hence the
#    static --ip on the kind bridge.
#  - Single OSD => size-1 pools (mon_allow_pool_size_one), for a lab only.
set -euo pipefail

CLUSTER="${CLUSTER:-ceph-test}"
CTX="kind-${CLUSTER}"
CEPH_NAME="${CEPH_NAME:-ceph}"
CEPH_IMAGE="${CEPH_IMAGE:-quay.io/ceph/demo:latest-reef}"
CLIENT_IMAGE="${CLIENT_IMAGE:-quay.io/ceph/ceph:v18}"
CEPH_IP="${CEPH_IP:-}"   # auto-picked from the kind subnet if empty

ceph() { docker exec "$CEPH_NAME" ceph "$@"; }

up() {
  kind create cluster --name "$CLUSTER"

  # Pick a static IP high in the kind IPv4 subnet.
  local subnet; subnet=$(docker network inspect kind \
    -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' \
    | tr ' ' '\n' | grep -E '^[0-9]+\.' | head -1)
  local base="${subnet%.*/*}"          # e.g. 192.168.167
  : "${CEPH_IP:=${base}.200}"
  echo ">> kind subnet=$subnet  ceph ip=$CEPH_IP"

  docker rm -f "$CEPH_NAME" >/dev/null 2>&1 || true
  docker run -d --name "$CEPH_NAME" --network kind --ip "$CEPH_IP" --platform linux/amd64 \
    -e MON_IP="$CEPH_IP" \
    -e CEPH_PUBLIC_NETWORK="${subnet}" \
    -e CEPH_DEMO_UID=report \
    -e CEPH_DEMO_ACCESS_KEY=demoaccess \
    -e CEPH_DEMO_SECRET_KEY=demosecret \
    "$CEPH_IMAGE" >/dev/null

  echo ">> waiting for ceph..."
  for _ in $(seq 1 40); do ceph -s >/dev/null 2>&1 && break; sleep 5; done

  # Single-OSD cluster: allow and set size 1 so PGs go active+clean.
  ceph config set global mon_allow_pool_size_one true
  ceph config set global osd_pool_default_size 1
  ceph config set global osd_pool_default_min_size 1
  local p
  for p in $(ceph osd pool ls); do
    ceph osd pool set "$p" size 1 --yes-i-really-mean-it >/dev/null 2>&1 || true
    ceph osd pool set "$p" min_size 1 >/dev/null 2>&1 || true
  done
  ceph crash archive-all >/dev/null 2>&1 || true

  # RBD pool + a couple of images for the report to find.
  ceph osd pool create rbd 32 >/dev/null 2>&1 || true
  ceph osd pool set rbd size 1 --yes-i-really-mean-it >/dev/null 2>&1 || true
  ceph osd pool application enable rbd rbd >/dev/null 2>&1 || true
  docker exec "$CEPH_NAME" rbd create rbd/testimg --size 1024 >/dev/null 2>&1 || true
  docker exec "$CEPH_NAME" rbd create rbd/scratch --size 512 >/dev/null 2>&1 || true

  # Read-only report user (rbd-read-only profile is needed to list rbd images).
  ceph auth get-or-create client.report \
    mon 'allow r' mgr 'allow r' mds 'allow r' \
    osd 'profile rbd-read-only pool=rbd, allow r' >/dev/null
  local key; key=$(ceph auth get-key client.report)

  cat <<EOF

================ ready ================
  kube context : $CTX
  mon host      : ${CEPH_IP}:6789 (v1) / ${CEPH_IP}:3300 (v2)
  client user   : client.report
  client key    : $key

Helm values for client mode (point the chart here):
  weekly.enabled=true
  weekly.ceph.mode=client
  weekly.ceph.client.monHost=${CEPH_IP}:6789
  weekly.ceph.client.auth.existingSecret=ceph-client   # keys userID/userKey
  (create: kubectl create secret generic ceph-client \\
     --from-literal=userID=report --from-literal=userKey=$key)
=======================================
EOF
}

probe() {
  local ip; ip=$(docker inspect "$CEPH_NAME" -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
  local key; key=$(ceph auth get-key client.report)
  kubectl --context "$CTX" delete pod cephprobe --ignore-not-found >/dev/null 2>&1 || true
  kubectl --context "$CTX" run cephprobe --image="$CLIENT_IMAGE" --restart=Never \
    --command -- sleep 600 >/dev/null
  kubectl --context "$CTX" wait --for=condition=Ready pod/cephprobe --timeout=300s
  echo ">> ceph -s"; kubectl --context "$CTX" exec cephprobe -- \
    ceph --conf /dev/null -m "$ip" --name client.report --key "$key" -s
  echo ">> rbd ls -l rbd"; kubectl --context "$CTX" exec cephprobe -- \
    rbd --conf /dev/null -m "$ip" --name client.report --key "$key" ls -l rbd
}

down() {
  kind delete cluster --name "$CLUSTER" || true
  docker rm -f "$CEPH_NAME" >/dev/null 2>&1 || true
}

case "${1:-up}" in
  up) up ;;
  probe) probe ;;
  down) down ;;
  *) echo "usage: $0 {up|probe|down}" >&2; exit 2 ;;
esac
