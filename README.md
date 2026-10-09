# ceph-reports

A Helm chart that deploys two Kubernetes CronJobs which email plain-text Ceph
reports (with JSON attachments) for a Rook-Ceph environment:

1. **Daily PVC → pod mapping** (`*-daily`) — lists every Ceph CSI PVC, its PV, the
   Ceph backing object (`pool/image` for RBD, `fsName/subvolume` for CephFS) and
   every pod + `container:mountPath` that mounts it. Read-only against the
   Kubernetes API. The subject carries total and unmounted counts.
2. **Weekly orphan report** (`*-weekly`) — Ceph objects with no PV in Kubernetes
   (with size, creation time and watcher count) and RBD trash contents. Reaches
   Ceph either through the Rook **toolbox** or as a direct **client** (for Rook
   *external mode* clusters with no toolbox).

Works on Kubernetes >= 1.27 (CronJob `timeZone`). Pods satisfy Pod Security
Standards **restricted**.

## Install

```sh
helm repo add ceph-reports https://sourcediver42.github.io/ceph-reports
helm repo update
helm install ceph-reports ceph-reports/ceph-reports \
  -n ceph-reports --create-namespace \
  --set smtp.existingSecret=smtp
```

Create the SMTP secret first (or point `smtp.existingSecret` at an existing one):

```sh
kubectl -n ceph-reports create secret generic smtp \
  --from-literal=SMTP_URL='smtp://smtp.example.com:587' \
  --from-literal=SMTP_USER='user' \
  --from-literal=SMTP_PASS='pass' \
  --from-literal=MAIL_FROM='ceph-reports@example.com' \
  --from-literal=MAIL_TO='you@example.com'
```

Trigger a one-off run to test:

```sh
kubectl -n ceph-reports create job --from=cronjob/ceph-reports-daily test-daily
```

## External Ceph (Rook external mode)

In external mode the admin toolbox usually does not exist, so run the weekly job
in **client** mode and **install the chart into your Rook external namespace** so
the credential secret and the mon-endpoints ConfigMap are local (a `secretKeyRef`
cannot cross namespaces).

> **Do not reuse the Rook CSI/mon secrets.** Their cephx caps are scoped to CSI's
> own job, so the report hits `Operation not permitted`. Verified against a real
> cluster:
>
> | Rook credential | denied on | why |
> |---|---|---|
> | `rook-csi-rbd-provisioner` | `ceph fs ls` | `mon 'profile rbd'` has no fsmap read |
> | `rook-csi-cephfs-provisioner` | `rbd ls` | `osd` cap is cephfs-tagged only |
> | `rook-ceph-mon` (healthchecker) | `ceph fs subvolume ls` | `mgr 'allow command config'` too narrow |
>
> Create one dedicated **read-only** user instead:
>
> ```sh
> ceph auth get-or-create client.report \
>   mon 'allow r' mgr 'allow r' mds 'allow r' osd 'profile rbd-read-only, allow r'
> kubectl -n rook-ceph-external create secret generic ceph-report-creds \
>   --from-literal=userID=report --from-literal=userKey=<key-from-above>
> ```

```yaml
# values-external.yaml
weekly:
  ceph:
    mode: client
    autoDiscover: true          # discover pools/filesystems from Ceph itself
    client:
      image:
        repository: quay.io/ceph/ceph   # must also contain kubectl, jq, curl, bash, python3
        tag: v18
      auth:
        existingSecret: ceph-report-creds   # dedicated read-only user (see above)
        userIDKey: userID
        userKeyKey: userKey
```

```sh
helm install ceph-reports ceph-reports/ceph-reports \
  -n rook-ceph-external -f values-external.yaml \
  --set smtp.existingSecret=smtp
```

> **Gotchas seen in testing**
> - *mon endpoint port:* the mon-endpoints ConfigMap lists `a=<ip>:6789` (msgr v1).
>   If your mons only bind msgr v2, use `:3300` or the client hangs on connect
>   (no error, just a stall) — the chart passes the value through verbatim.
> - *self-signed SMTP CA:* trust it with `smtp.caSecret` (a Secret) or
>   `smtp.caConfigMap` (a ConfigMap — e.g. a cert-manager **trust-manager** Bundle,
>   whose default target is a ConfigMap synced to every namespace). It mounts into
>   the report container only and sets `SSL_CERT_FILE`, so your internal CA alone is
>   enough — no need to include public CAs:
>   ```sh
>   # trust-manager Bundle already present in the namespace:
>   --set smtp.caConfigMap=ceph-reports-trust --set smtp.caConfigMapKey=ca-certificates.crt
>   # or a plain Secret:
>   kubectl create secret generic smtp-ca --from-file=ca.crt=ca.pem
>   --set smtp.caSecret=smtp-ca
>   ```
>   (The older `weekly.extraEnv`/`extraVolumeMounts` route still works but also hits
>   the tools init container, so it needs a public+private bundle — prefer the above.)
> - *quick bypass (testing only):* `--set smtp.insecure=true` skips SMTP TLS
>   verification entirely. Never use it against a real mail server.

Alternatively, mount a keyring file instead of reusing a secret:

```yaml
weekly:
  ceph:
    client:
      user: ceph-reports-ro
      keyringSecret: ceph-reports-keyring   # Secret with a keyring file
      keyringSecretKey: keyring
```

## Ceph access modes

| Mode | How it reaches Ceph | RBAC created in Ceph namespace | Use when |
|------|---------------------|--------------------------------|----------|
| `toolbox` (default) | `kubectl exec` into `deploy/rook-ceph-tools` | `pods`, `pods/exec`, `deployments:get` | Classic Rook with a toolbox |
| `client` | Runs `rbd`/`ceph` in the job pod against the mons | `configmaps:get` (mon-endpoints) | Rook external mode / no toolbox |

## Key values

| Key | Default | Description |
|-----|---------|-------------|
| `namespaceOverride` | `""` (release ns) | Namespace for all namespaced resources; no `Namespace` object is created. |
| `commonLabels` / `commonAnnotations` | `{}` | Applied to **every** resource. |
| `common.podLabels` / `common.podAnnotations` | `{}` | Applied to both job pods; per-job `daily.*`/`weekly.*` deep-merge on top. |
| `common.podSecurityContext` | PSS restricted | Pod securityContext (runAsNonRoot, seccomp RuntimeDefault, …). Per-job overridable. |
| `common.securityContext` | PSS restricted | Container securityContext (drop ALL, readOnlyRootFilesystem, …). |
| `image.*` | `alpine/k8s:1.31.2` | Shared image (kubectl + jq + curl + bash; python3 recommended). `registry`, `repository`, `tag`, `digest`, `pullPolicy`. |
| `imagePullSecrets` | `[]` | Pull secrets for private registries/mirrors. |
| `serviceAccount.{create,name,annotations}` | create: true | ServiceAccount. |
| `rbac.create` | `true` | Cluster read role (pods, PVCs, PVs). |
| `rbac.toolboxAccess.create` | `true` | Role/RoleBinding in the Ceph namespace for the weekly job. |
| `smtp.existingSecret` | `""` | Reference an existing SMTP secret (highest priority). |
| `smtp.keys.{url,user,pass,from,to}` | `SMTP_*`/`MAIL_*` | Secret key names (remap to match your secret). |
| `smtp.secret.create` | `false` | Render an inline secret from values (DEV ONLY). |
| `mail.subjectPrefix` | `[rook]` | Subject prefix for all report emails. |
| `mail.clusterName` | `""` | Appended to the subject as `<prefix> [<clusterName>]`. Set per environment. |
| `mail.clusterNameFrom.enabled` | `false` | Best-effort: read the cluster name from a ConfigMap at runtime when `clusterName` is empty. |
| `daily.*` / `weekly.*` | see `values.yaml` | Per-job `enabled`, `schedule`, `timeZone`, `concurrencyPolicy`, history limits, `backoffLimit`, `ttlSecondsAfterFinished`, `suspend`, `resources`, `nodeSelector`, `tolerations`, `affinity`, `extraEnv`, `extraVolumes`, `extraVolumeMounts`. |
| `weekly.ceph.client.toolsInit.*` | `enabled: true`, `mountPath: /opt/tools/bin` | Client mode only: init container that stages static `kubectl` + `jq` onto `PATH`, so the main image can be a plain `ceph` image pinned to the cluster version. Set `image.*` to override the tools image (defaults to the shared chart image). |
| `weekly.ceph.mode` | `toolbox` | `toolbox` or `client`. |
| `weekly.ceph.autoDiscover` | `true` | Discover pools/filesystems when the lists are empty. |
| `weekly.ceph.rbdPools` | `[]` | RBD pools to scan (empty + autoDiscover = discover). |
| `weekly.ceph.cephfs.names` | `[]` | CephFS filesystems to scan. |

See [`values.yaml`](values.yaml) for the full, documented list.

## Cluster name in the subject

Kubernetes has no universal "cluster name" API, so set it explicitly per
environment (works well with per-environment GitOps values):

```yaml
mail:
  clusterName: turing   # subjects become "[rook] [turing] ..."
```

Optionally auto-detect it from a ConfigMap at runtime (creates a `configmaps:get`
Role in that namespace):

```yaml
mail:
  clusterNameFrom:
    enabled: true
    configMap:
      name: kubeadm-config
      namespace: kube-system
      key: clusterName   # adjust to your ConfigMap's layout
```

## Email

Reports are sent with a small Python sender (`smtplib`) that supports attachments,
so each email carries the structured JSON (`mapping.json` for daily;
`orphans.json` for weekly). If `python3` is not present in the
image, it falls back to `curl` (text body only, with a logged warning).

## Safety

The weekly job **fails loudly** (non-zero exit + an alert email) if a configured
or discovered Ceph pool/filesystem cannot be listed, rather than silently
reporting an empty — and therefore falsely "all-clear" — orphan list.

## Secret sources (priority order)

1. `smtp.existingSecret` — reference a pre-existing Secret.
2. `smtp.secret.create` — render an inline Secret from values (**dev only**).

## License

See repository.
