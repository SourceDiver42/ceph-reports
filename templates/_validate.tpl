{{/*
Fail fast on invalid combinations that JSON Schema can't express cleanly.
*/}}
{{- define "ceph-reports.validate" -}}
{{- if or .Values.daily.enabled .Values.weekly.enabled -}}
{{- if not (or .Values.smtp.existingSecret .Values.smtp.secret.create) -}}
{{- fail "No SMTP secret source configured. Set smtp.existingSecret or smtp.secret.create when daily.enabled or weekly.enabled is true." -}}
{{- end -}}
{{- end -}}
{{- if and .Values.weekly.enabled (eq .Values.weekly.ceph.mode "client") -}}
{{- $c := .Values.weekly.ceph.client -}}
{{- if not $c.image.repository -}}
{{- fail "weekly.ceph.mode is 'client' but weekly.ceph.client.image.repository is empty. Set an image containing ceph-common plus kubectl, jq, curl, bash and python3." -}}
{{- end -}}
{{- if not (or $c.auth.existingSecret $c.keyringSecret) -}}
{{- fail "weekly.ceph.mode is 'client' but no credentials are configured. Set weekly.ceph.client.auth.existingSecret (reuse a Rook secret) or weekly.ceph.client.keyringSecret (a keyring file)." -}}
{{- end -}}
{{- end -}}
{{- end -}}
