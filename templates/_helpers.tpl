{{/*
Chart name, optionally overridden.
*/}}
{{- define "ceph-reports.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Fully qualified app name, truncated to 63 chars (DNS label limit).
*/}}
{{- define "ceph-reports.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Chart label value.
*/}}
{{- define "ceph-reports.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Namespace for namespaced resources. Defaults to the release namespace; override
with namespaceOverride. No Namespace resource is ever templated.
*/}}
{{- define "ceph-reports.namespace" -}}
{{- default .Release.Namespace .Values.namespaceOverride -}}
{{- end -}}

{{/*
Namespace the weekly job needs RBAC in: the toolbox namespace in toolbox mode,
or the mon-endpoints namespace (default: release namespace) in client mode.
*/}}
{{- define "ceph-reports.cephAccessNamespace" -}}
{{- if eq .Values.weekly.ceph.mode "client" -}}
{{- default (include "ceph-reports.namespace" .) .Values.weekly.ceph.client.monEndpointsNamespace -}}
{{- else -}}
{{- default "rook-ceph" .Values.weekly.ceph.toolbox.namespace -}}
{{- end -}}
{{- end -}}

{{/*
Common labels applied to every resource. Merges chart-standard labels with the
user-supplied commonLabels (user keys win).
*/}}
{{- define "ceph-reports.labels" -}}
{{- $std := dict
  "helm.sh/chart" (include "ceph-reports.chart" .)
  "app.kubernetes.io/managed-by" .Release.Service
-}}
{{- if .Chart.AppVersion -}}
{{- $_ := set $std "app.kubernetes.io/version" (.Chart.AppVersion | quote | trimAll "\"") -}}
{{- end -}}
{{- $sel := fromYaml (include "ceph-reports.selectorLabels" .) -}}
{{- $all := merge (deepCopy (.Values.commonLabels | default dict)) $std $sel -}}
{{- toYaml $all -}}
{{- end -}}

{{/*
Selector labels. Stable across upgrades; never put mutable data here.
*/}}
{{- define "ceph-reports.selectorLabels" -}}
app.kubernetes.io/name: {{ include "ceph-reports.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Common annotations applied to every resource.
*/}}
{{- define "ceph-reports.annotations" -}}
{{- with .Values.commonAnnotations -}}
{{- toYaml . -}}
{{- end -}}
{{- end -}}

{{/*
ServiceAccount name to use.
*/}}
{{- define "ceph-reports.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "ceph-reports.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/*
Container image reference, honouring an optional digest pin.
*/}}
{{- define "ceph-reports.image" -}}
{{- $img := .Values.image -}}
{{- $repo := $img.repository -}}
{{- if $img.registry -}}
{{- $repo = printf "%s/%s" $img.registry $img.repository -}}
{{- end -}}
{{- if $img.digest -}}
{{- printf "%s@%s" $repo $img.digest -}}
{{- else -}}
{{- printf "%s:%s" $repo (default .Chart.AppVersion $img.tag) -}}
{{- end -}}
{{- end -}}

{{/*
Image for the weekly job: uses weekly.ceph.client.image in client mode (needs
ceph-common), otherwise the shared image.
*/}}
{{- define "ceph-reports.weekly.image" -}}
{{- if and (eq .Values.weekly.ceph.mode "client") .Values.weekly.ceph.client.image.repository -}}
{{- $img := .Values.weekly.ceph.client.image -}}
{{- $repo := $img.repository -}}
{{- if $img.registry -}}
{{- $repo = printf "%s/%s" $img.registry $img.repository -}}
{{- end -}}
{{- if $img.digest -}}
{{- printf "%s@%s" $repo $img.digest -}}
{{- else -}}
{{- printf "%s:%s" $repo ($img.tag | default "latest") -}}
{{- end -}}
{{- else -}}
{{- include "ceph-reports.image" . -}}
{{- end -}}
{{- end -}}

{{/*
Image for the client-mode tools init container (provides kubectl + jq). Defaults
to the shared chart image, which already carries both static binaries.
*/}}
{{- define "ceph-reports.weekly.toolsImage" -}}
{{- $init := .Values.weekly.ceph.client.toolsInit -}}
{{- if $init.image.repository -}}
{{- $img := $init.image -}}
{{- $repo := $img.repository -}}
{{- if $img.registry -}}
{{- $repo = printf "%s/%s" $img.registry $img.repository -}}
{{- end -}}
{{- if $img.digest -}}
{{- printf "%s@%s" $repo $img.digest -}}
{{- else -}}
{{- printf "%s:%s" $repo ($img.tag | default "latest") -}}
{{- end -}}
{{- else -}}
{{- include "ceph-reports.image" . -}}
{{- end -}}
{{- end -}}

{{/*
Name of the Secret holding SMTP credentials.
*/}}
{{- define "ceph-reports.secretName" -}}
{{- if .Values.smtp.existingSecret -}}
{{- .Values.smtp.existingSecret -}}
{{- else -}}
{{- printf "%s-smtp" (include "ceph-reports.fullname" .) -}}
{{- end -}}
{{- end -}}

{{/*
Merged pod-level securityContext for a job. Usage:
  {{ include "ceph-reports.podSecurityContext" (dict "ctx" . "job" .Values.daily) }}
Per-job values override common; both are deep-merged.
*/}}
{{- define "ceph-reports.podSecurityContext" -}}
{{- $merged := merge (deepCopy (.job.podSecurityContext | default dict)) (.ctx.Values.common.podSecurityContext | default dict) -}}
{{- with $merged -}}
{{- toYaml . -}}
{{- end -}}
{{- end -}}

{{/*
Merged container-level securityContext for a job.
*/}}
{{- define "ceph-reports.securityContext" -}}
{{- $merged := merge (deepCopy (.job.securityContext | default dict)) (.ctx.Values.common.securityContext | default dict) -}}
{{- with $merged -}}
{{- toYaml . -}}
{{- end -}}
{{- end -}}

{{/*
Merged pod labels for a job (common.podLabels + per-job podLabels; per-job wins).
*/}}
{{- define "ceph-reports.podLabels" -}}
{{- $merged := merge (deepCopy (.job.podLabels | default dict)) (.ctx.Values.common.podLabels | default dict) -}}
{{- with $merged -}}
{{- toYaml . -}}
{{- end -}}
{{- end -}}

{{/*
Merged pod annotations for a job (common.podAnnotations + per-job; per-job wins).
*/}}
{{- define "ceph-reports.podAnnotations" -}}
{{- $merged := merge (deepCopy (.job.podAnnotations | default dict)) (.ctx.Values.common.podAnnotations | default dict) -}}
{{- with $merged -}}
{{- toYaml . -}}
{{- end -}}
{{- end -}}

{{/*
Environment mapping the configurable SMTP secret keys to the canonical variable
names the scripts expect, plus the subject prefix. Keeps custom key names working.
*/}}
{{- define "ceph-reports.smtpEnv" -}}
{{- $secret := include "ceph-reports.secretName" . -}}
{{- $keys := .Values.smtp.keys -}}
- name: SUBJECT_PREFIX
  value: {{ .Values.mail.subjectPrefix | quote }}
- name: CLUSTER_NAME
  value: {{ .Values.mail.clusterName | quote }}
{{- if .Values.mail.clusterNameFrom.enabled }}
- name: CLUSTER_NAME_CM
  value: {{ .Values.mail.clusterNameFrom.configMap.name | quote }}
- name: CLUSTER_NAME_CM_NS
  value: {{ .Values.mail.clusterNameFrom.configMap.namespace | quote }}
- name: CLUSTER_NAME_CM_KEY
  value: {{ .Values.mail.clusterNameFrom.configMap.key | quote }}
{{- end }}
- name: SMTP_URL
  valueFrom:
    secretKeyRef:
      name: {{ $secret }}
      key: {{ $keys.url }}
- name: SMTP_USER
  valueFrom:
    secretKeyRef:
      name: {{ $secret }}
      key: {{ $keys.user }}
- name: SMTP_PASS
  valueFrom:
    secretKeyRef:
      name: {{ $secret }}
      key: {{ $keys.pass }}
- name: MAIL_FROM
  valueFrom:
    secretKeyRef:
      name: {{ $secret }}
      key: {{ $keys.from }}
- name: MAIL_TO
  valueFrom:
    secretKeyRef:
      name: {{ $secret }}
      key: {{ $keys.to }}
{{- if .Values.smtp.insecure }}
- name: SMTP_INSECURE
  value: "1"
{{- end }}
{{- end -}}
