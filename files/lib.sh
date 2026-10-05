#!/usr/bin/env bash
# Shared helpers sourced by daily.sh and weekly.sh.
set -euo pipefail

# send_mail <subject> <bodyfile> [attachment ...]
# Prefers the Python sender (supports attachments, e.g. the JSON reports). Falls
# back to curl (text body only) when python3 is unavailable, so a missing
# interpreter degrades gracefully instead of dropping the report entirely.
send_mail() {
  local subject="$1" bodyfile="$2"
  shift 2
  if command -v python3 >/dev/null 2>&1; then
    python3 /scripts/send_mail.py "$subject" "$bodyfile" "$@"
    return
  fi

  if [ "$#" -gt 0 ]; then
    echo "WARN: python3 not found; sending text-only email without attachments ($*)" >&2
  fi
  local msg=/tmp/msg.eml
  {
    printf 'From: %s\n' "$MAIL_FROM"
    printf 'To: %s\n' "$MAIL_TO"
    printf 'Subject: %s\n' "$subject"
    printf 'Date: %s\n' "$(date -R)"
    printf 'MIME-Version: 1.0\n'
    printf 'Content-Type: text/plain; charset=utf-8\n\n'
    cat "$bodyfile"
  } | sed 's/$/\r/' > "$msg"

  local insecure=
  case "$(printf '%s' "${SMTP_INSECURE:-}" | tr 'A-Z' 'a-z')" in
    1|true|yes) insecure=--insecure ;;
  esac
  curl --fail --silent --show-error --ssl-reqd $insecure \
    --url "$SMTP_URL" \
    --user "$SMTP_USER:$SMTP_PASS" \
    --mail-from "$MAIL_FROM" \
    --mail-rcpt "$MAIL_TO" \
    --upload-file "$msg"
}

# Best-effort alert used when a report cannot be produced. Never aborts the
# caller (so the original failure exit code is preserved) but makes the breakage
# visible by email instead of a silent empty report.
alert_mail() {
  local subject="$1" body="$2" f=/tmp/alert.txt
  printf '%s\n' "$body" > "$f"
  send_mail "$subject" "$f" || true
}

# Best-effort cluster-name resolution from a ConfigMap when not set explicitly.
if [ -z "${CLUSTER_NAME:-}" ] && [ -n "${CLUSTER_NAME_CM:-}" ]; then
  CLUSTER_NAME="$(kubectl -n "${CLUSTER_NAME_CM_NS:-kube-system}" get configmap "${CLUSTER_NAME_CM}" \
    -o jsonpath="{.data.${CLUSTER_NAME_CM_KEY:-clusterName}}" 2>/dev/null || true)"
  export CLUSTER_NAME
fi

# Effective subject prefix: "<subjectPrefix> [<clusterName>]" when a cluster name is known.
mail_prefix() {
  local p="${SUBJECT_PREFIX:-[ceph]}"
  [ -n "${CLUSTER_NAME:-}" ] && p="${p} [${CLUSTER_NAME}]"
  printf '%s' "$p"
}

# jq filter: Ceph CSI PVs only (rbd + cephfs, any rook namespace prefix)
CEPH_PV_FILTER='select((.spec.csi.driver // "") | test("csi\\.ceph\\.com$"))'
