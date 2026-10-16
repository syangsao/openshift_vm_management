# Talking to the API directly

Everything `oc` and `virtctl` do is a REST call to `kube-apiserver`. This document
shows how to make those calls yourself — useful for automation, CI, and for
understanding exactly what the higher-level tools do.

## Base URL and authentication

```bash
SERVER=$(oc whoami --show-server)          # https://api.<cluster>:6443
echo "$SERVER"
```

### Option A — client certificate (from the kubeconfig)

```bash
KCONF="${KUBECONFIG:-$HOME/.kube/config}"
OUT=$(mktemp -d)

oc config view --raw --minify --kubeconfig "$KCONF" \
  -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d > "$OUT/ca.crt"
oc config view --raw --minify --kubeconfig "$KCONF" \
  -o jsonpath='{.users[0].user.client-certificate-data}' | base64 -d > "$OUT/client.crt"
oc config view --raw --minify --kubeconfig "$KCONF" \
  -o jsonpath='{.users[0].user.client-key-data}' | base64 -d > "$OUT/client.key"

curl -s \
  --cacert "$OUT/ca.crt" \
  --cert   "$OUT/client.crt" \
  --key    "$OUT/client.key" \
  "$SERVER/apis/kubevirt.io/v1" | python3 -m json.tool
```

### Option B — bearer token

```bash
TOKEN=$(oc whoami -t)      # fails if the session uses client certs
curl -s -H "Authorization: Bearer $TOKEN" "$SERVER/apis/kubevirt.io/v1"
```

A long-lived token for a service account:

```bash
oc create token my-sa -n vms --duration=24h
```

Set it once for the rest of a shell session:

```bash
export SERVER=$(oc whoami --show-server)
export TOKEN=$(oc whoami -t)
export CURL="curl -s -H \"Authorization: Bearer $TOKEN\" -H 'Accept: application/json'"

# or with the extracted certs
export CURL="curl -s --cacert $OUT/ca.crt --cert $OUT/client.crt --key $OUT/client.key"
```

## URL structure

```
{SERVER}/apis/{group}/{version}/namespaces/{namespace}/{resource}[/{name}]
```

| Object | Path |
| --- | --- |
| `VirtualMachine` | `/apis/kubevirt.io/v1/namespaces/{ns}/virtualmachines` |
| `VirtualMachineInstance` | `/apis/kubevirt.io/v1/namespaces/{ns}/virtualmachineinstances` |
| `VirtualMachineInstanceMigration` | `/apis/kubevirt.io/v1/namespaces/{ns}/virtualmachineinstancemigrations` |
| `VirtualMachineSnapshot` | `/apis/snapshot.kubevirt.io/v1beta1/namespaces/{ns}/virtualmachinesnapshots` |
| `VirtualMachineRestore` | `/apis/snapshot.kubevirt.io/v1beta1/namespaces/{ns}/virtualmachinerestores` |
| `VirtualMachineClone` | `/apis/clone.kubevirt.io/v1beta1/namespaces/{ns}/virtualmachineclones` |
| `VirtualMachineExport` | `/apis/export.kubevirt.io/v1beta1/namespaces/{ns}/virtualmachineexports` |
| `VirtualMachinePool` | `/apis/pool.kubevirt.io/v1beta1/namespaces/{ns}/virtualmachinepools` |
| `DataVolume` | `/apis/cdi.kubevirt.io/v1beta1/namespaces/{ns}/datavolumes` |
| `DataSource` | `/apis/cdi.kubevirt.io/v1beta1/namespaces/{ns}/datasources` |
| `VirtualMachineClusterInstancetype` | `/apis/instancetype.kubevirt.io/v1beta1/virtualmachineclusterinstancetypes` (cluster-scoped) |
| `VirtualMachineInstancetype` | `/apis/instancetype.kubevirt.io/v1beta1/namespaces/{ns}/virtualmachineinstancetypes` |
| `MigrationPolicy` | `/apis/migrations.kubevirt.io/v1alpha1/migrationpolicies` (cluster-scoped) |
| `VirtualMachineBackup` | `/apis/backup.kubevirt.io/v1alpha1/namespaces/{ns}/virtualmachinebackups` |

Discover them at runtime rather than hard-coding:

```bash
curl -s $CURL "$SERVER/apis" | python3 -c "import json,sys; [print(a['name']) for a in json.load(sys.stdin)['groups']]"
curl -s $CURL "$SERVER/apis/kubevirt.io/v1" | python3 -c "import json,sys; [print(r['name'], r.get('namespaced')) for r in json.load(sys.stdin)['resources']]"
```

## Verbs

| Verb | HTTP | Purpose |
| --- | --- | --- |
| Read | `GET` | Fetch one object or a list |
| Create | `POST` | Submit a new object |
| Replace | `PUT` | Full overwrite |
| Update | `PATCH` | Partial change |
| Delete | `DELETE` | Remove |

### GET

```bash
# List
curl -s $CURL "$SERVER/apis/kubevirt.io/v1/namespaces/vms/virtualmachines" | python3 -m json.tool

# Just the names
curl -s $CURL "$SERVER/apis/kubevirt.io/v1/namespaces/vms/virtualmachines" \
  | python3 -c "import json,sys; [print(i['metadata']['name']) for i in json.load(sys.stdin)['items']]"

# One object
curl -s $CURL "$SERVER/apis/kubevirt.io/v1/namespaces/vms/virtualmachines/web-01" | python3 -m json.tool

# Field selection (server-side filtering)
curl -s $CURL "$SERVER/apis/kubevirt.io/v1/namespaces/vms/virtualmachines?fieldSelector=metadata.name=web-01"

# Label selection
curl -s $CURL "$SERVER/apis/kubevirt.io/v1/namespaces/vms/virtualmachines?labelSelector=app%3Dweb"

# Watch - streams newline-delimited JSON events
curl -s $CURL "$SERVER/apis/kubevirt.io/v1/namespaces/vms/virtualmachines?watch=true"
```

### POST (create)

```bash
curl -s $CURL -X POST \
  -H 'Content-Type: application/json' \
  "$SERVER/apis/kubevirt.io/v1/namespaces/vms/virtualmachines" \
  -d @- <<'JSON'
{
  "apiVersion": "kubevirt.io/v1",
  "kind": "VirtualMachine",
  "metadata": { "name": "web-01", "namespace": "vms" },
  "spec": {
    "runStrategy": "Always",
    "template": {
      "spec": {
        "domain": { "devices": {} },
        "volumes": []
      }
    }
  }
}
JSON
```

Or send YAML — the API accepts `application/yaml`:

```bash
curl -s $CURL -X POST \
  -H 'Content-Type: application/yaml' \
  "$SERVER/apis/kubevirt.io/v1/namespaces/vms/virtualmachines" \
  --data-binary @rhel9-full-example.yaml
```

### PATCH (update)

Three patch types; pick the one that matches what you need.

**Merge patch** (`application/merge-patch+json`) — recursive merge, simplest, but
it **replaces whole lists**:

```bash
curl -s $CURL -X PATCH \
  -H 'Content-Type: application/merge-patch+json' \
  "$SERVER/apis/kubevirt.io/v1/namespaces/vms/virtualmachines/web-01" \
  -d '{"spec":{"template":{"spec":{"domain":{"cpu":{"sockets":4}}}}}}'
```

**Strategic merge patch** (`application/strategic-merge-patch+json`) — merges
lists by key instead of replacing them. Use this when touching `volumes`,
`disks`, `interfaces` or `networks`:

```bash
curl -s $CURL -X PATCH \
  -H 'Content-Type: application/strategic-merge-patch+json' \
  "$SERVER/apis/kubevirt.io/v1/namespaces/vms/virtualmachines/web-01" \
  -d '{"spec":{"template":{"spec":{"domain":{"devices":{"disks":[{"name":"data","disk":{"bus":"virtio"}}]}}}}}}'
```

**JSON patch** (`application/json-patch+json`) — explicit operations, the right
tool for appending to or removing from a list:

```bash
# Append a network interface
curl -s $CURL -X PATCH \
  -H 'Content-Type: application/json-patch+json' \
  "$SERVER/apis/kubevirt.io/v1/namespaces/vms/virtualmachines/web-01" \
  -d '[
        {"op":"add","path":"/spec/template/spec/networks/-",
         "value":{"name":"vlan60","multus":{"networkName":"default/vlan-60"}}}
      ]'
```

| Patch type | Content-Type | List behaviour |
| --- | --- | --- |
| Merge | `application/merge-patch+json` | **Replaces** the entire list |
| Strategic merge | `application/strategic-merge-patch+json` | Merges by key |
| JSON patch | `application/json-patch+json` | Explicit `add`/`remove`/`replace` |

### DELETE

```bash
curl -s $CURL -X DELETE \
  "$SERVER/apis/kubevirt.io/v1/namespaces/vms/virtualmachines/web-01"

# Propagation policy matters - see 04-delete/
curl -s $CURL -X DELETE \
  "$SERVER/apis/kubevirt.io/v1/namespaces/vms/virtualmachines/web-01?propagationPolicy=Orphan"
```

| `propagationPolicy` | Effect on dependents (DataVolumes, PVCs) |
| --- | --- |
| `Background` (default) | Delete the owner now, dependents afterwards |
| `Foreground` | Delete dependents first, then the owner |
| `Orphan` | **Leave dependents alive** — the safe option for preserving disks |

## Dry run

Validate without persisting. `--dry-run=server` runs the real admission webhooks
and defaulting, which is what you want:

```bash
curl -s $CURL -X POST \
  -H 'Content-Type: application/yaml' \
  "$SERVER/apis/kubevirt.io/v1/namespaces/vms/virtualmachines?dryRun=All" \
  --data-binary @my-vm.yaml
```

## Subresources

```bash
# Start / stop a VM (the subresource virtctl uses)
curl -s $CURL -X PUT \
  "$SERVER/apis/subresources.kubevirt.io/v1/namespaces/vms/virtualmachines/web-01/start"

curl -s $CURL -X PUT \
  "$SERVER/apis/subresources.kubevirt.io/v1/namespaces/vms/virtualmachines/web-01/stop"

curl -s $CURL -X PUT \
  "$SERVER/apis/subresources.kubevirt.io/v1/namespaces/vms/virtualmachines/web-01/restart"
```

List the available subresources:

```bash
curl -s $CURL "$SERVER/apis/subresources.kubevirt.io/v1" | python3 -m json.tool
```

## Status and scale subresources

```bash
# Scale a pool via the scale subresource
curl -s $CURL -X PUT \
  -H 'Content-Type: application/json' \
  "$SERVER/apis/pool.kubevirt.io/v1beta1/namespaces/vms/virtualmachinepools/my-pool/scale" \
  -d '{"apiVersion":"autoscaling/v1","kind":"Scale","metadata":{"name":"my-pool","namespace":"vms"},"spec":{"replicas":5}}'
```

## OpenAPI schema

```bash
curl -s $CURL "$SERVER/openapi/v3/apis/kubevirt.io/v1" | python3 -m json.tool | head -60
curl -s $CURL "$SERVER/openapi/v3" | python3 -c "import json,sys; print('\n'.join(json.load(sys.stdin)['paths'].keys()))"
```

## Practical notes

- **Always use `?dryRun=All` first** when scripting a mutation.
- **`resourceVersion`** — include it in `PUT` for optimistic concurrency; omit it
  in `PATCH` unless you want conflict detection.
- **Lists replace on merge patch.** This is the most common scripting bug with
  VMs, because `volumes`, `disks`, `interfaces` and `networks` are all lists.
- **Impersonation** for testing RBAC without changing credentials:
  `-H 'Impersonate-User: alice' -H 'Impersonate-Group: system:authenticated'`.
- **Timeouts** — long operations return immediately; poll `status.phase` rather
  than holding a request open.
