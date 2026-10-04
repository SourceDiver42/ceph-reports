#!/usr/bin/env bash
# Daily report: every Ceph CSI PVC, its PV, the Ceph backing object, and the
# pods (container:mountPath) that mount it. Read-only against the Kubernetes API.
# Emits a structured mapping.json (attached to the email) and a text body.
source /scripts/lib.sh
cd /tmp

generated=$(date -u +'%F %T UTC')

kubectl get pv   -o json > pv.json
kubectl get pvc  -A -o json > pvc.json
kubectl get pods -A -o json > pods.json

# Build a single structured JSON model. The text body and the subject-line counts
# are both derived from this model, so nothing depends on grepping prose.
jq --arg generated "$generated" \
   --slurpfile pv pv.json --slurpfile pods pods.json '
  ($pv[0].items
    | map(select((.spec.csi.driver // "") | test("csi\\.ceph\\.com$")))
    | map({key: .metadata.name, value: .})
    | from_entries) as $pvs
  | ($pods[0].items
    | map(. as $p
        | (($p.spec.volumes // [])
          | map(select(.persistentVolumeClaim))
          | map(. as $v | {
              claim: "\($p.metadata.namespace)/\($v.persistentVolumeClaim.claimName)",
              pod: "\($p.metadata.namespace)/\($p.metadata.name)",
              phase: $p.status.phase,
              mounts: ([($p.spec.containers + ($p.spec.initContainers // []))[]
                        | . as $c
                        | ($c.volumeMounts // [])[]
                        | select(.name == $v.name)
                        | "\($c.name):\(.mountPath)\(if .readOnly then " (ro)" else "" end)"])
            })))
    | add // []
    | group_by(.claim)
    | map({key: .[0].claim, value: .})
    | from_entries) as $use
  | (.items
     | map(select($pvs[.spec.volumeName // ""] != null))
     | sort_by([.metadata.namespace, .metadata.name])
     | map(. as $c
         | $pvs[$c.spec.volumeName] as $v
         | ("\($c.metadata.namespace)/\($c.metadata.name)") as $key
         | {
             namespace: $c.metadata.namespace,
             name: $c.metadata.name,
             pvc: $key,
             storage: ($c.spec.resources.requests.storage // null),
             storageClass: ($c.spec.storageClassName // null),
             pv: $v.metadata.name,
             ceph: "\($v.spec.csi.volumeAttributes.pool // $v.spec.csi.volumeAttributes.fsName // "?")/\($v.spec.csi.volumeAttributes.imageName // $v.spec.csi.volumeAttributes.subvolumeName // "?")",
             mountedBy: ($use[$key] // [])
           })) as $items
  | {
      generated: $generated,
      total: ($items | length),
      unmounted: ([$items[] | select((.mountedBy | length) == 0)] | length),
      items: $items
    }
' pvc.json > mapping.json

total=$(jq -r '.total' mapping.json)
unmounted=$(jq -r '.unmounted' mapping.json)

# Human-readable body derived from the same model.
jq -r '
  .items[]
  | "\(.pvc)  [\(.storage // "?"), \(.storageClass // "-")]\n"
    + "   PV:   \(.pv)\n"
    + "   Ceph: \(.ceph)\n"
    + (if (.mountedBy | length) == 0 then "   (not mounted by any pod)\n"
       else (.mountedBy | map("   -> \(.pod) [\(.phase)] \(.mounts | join(", "))") | join("\n")) + "\n" end)
' mapping.json > body.txt

{
  echo "Rook-Ceph PVC -> pod/volumeMount mapping"
  echo "Generated: ${generated}"
  echo "PVCs: ${total}  (not mounted: ${unmounted})"
  echo
  cat body.txt
} > report.txt

send_mail "${SUBJECT_PREFIX:-[ceph]} Daily PVC mapping: ${total} PVCs, ${unmounted} unmounted" \
  report.txt mapping.json
