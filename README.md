# openshift_vm_api

Working **API examples** for managing virtual machines on OpenShift Virtualization
(OpenShift Container Platform 4.22, KubeVirt `v1`).

Everything here is the API itself — the CRD objects you submit, the REST calls
they become, and the `oc` invocations that wrap them. No wrapper scripts.

---

## Contents

| Directory | Covers |
| --- | --- |
| [`docs/`](docs/) | API surface, boot sources, networking, storage, and the raw REST API |
| [`01-deploy/`](01-deploy/) | Deploy RHEL 9, RHEL 10, Windows 2025 with subnet/IP, OS disk, data disks, vCPU, RAM, OS version, affinity/anti-affinity |
| [`02-lifecycle/`](02-lifecycle/) | Power operations, live migration to another compute server, node maintenance |
| [`03-scaling/`](03-scaling/) | Increase/decrease vCPU, RAM, disks, NICs — hot-plug where supported |
| [`04-delete/`](04-delete/) | Delete a VM **and** its ancillary components, safely |
| [`05-operators/`](05-operators/) | The other VM lifecycle controllers: pools, clones, snapshots, backups, exports |

Start with [`docs/02-api-surface.md`](docs/02-api-surface.md) for the object
model, and [`docs/04-rest-api.md`](docs/04-rest-api.md) if you are calling the
API server directly rather than through `oc`.

> Every manifest in this repository is validated with
> `oc apply --dry-run=server` against a live 4.22 cluster. Where a valid object
> is still *rejected* — because a feature gate is off, or because a runtime
> precondition is unmet — that is called out in the file and in
> [`docs/05-feature-gates.md`](docs/05-feature-gates.md).

---

## The thing to understand first

There is no separate "OpenShift Virtualization API". The API **is** the KubeVirt
API served by your cluster's `kube-apiserver`:

```bash
oc api-resources --api-group=kubevirt.io
oc explain virtualmachine.spec
oc get --raw /openapi/v3/apis/kubevirt.io/v1
```

`oc explain` and the OpenAPI schema are the authoritative reference — always
prefer them over prose.

A VM **is** an API object. `virtctl start` is a `PUT` to a subresource.
`virtctl addvolume` is a `PUT` to `addvolume`. Every example in this repository
shows the object, the `oc` call, and the raw REST call where they differ.

## API support tiers

OpenShift assigns every API group a support tier. For VM work in 4.22:

| Group | Version | Tier |
| --- | --- | --- |
| `kubevirt.io` (VM, VMI, VMIM, VMIRS) | `v1` | **1** — stable across major versions |
| `cdi.kubevirt.io` (DataVolume, DataSource, DataImportCron) | `v1beta1` | **2** — 9 months / 3 releases notice |
| `instancetype.kubevirt.io` | `v1beta1` | **2** |
| `pool.kubevirt.io` (VirtualMachinePool) | `v1beta1` | **2** |
| `clone.kubevirt.io` | `v1beta1` | **2** |
| `snapshot.kubevirt.io` | `v1beta1` | **2** |
| `export.kubevirt.io` | `v1beta1` | **2** |
| `migrations.kubevirt.io` (MigrationPolicy) | `v1alpha1` | **4** — no guarantee |
| `backup.kubevirt.io` (VirtualMachineBackup) | `v1alpha1` | **4** |
| `aaq.kubevirt.io` | `v1alpha1` | **4** |

Build on tier 1 for anything long-lived. Treat tier 4 as experimental.

---

## Prerequisites

```bash
# OpenShift CLI
oc version --client

# OpenShift Virtualization installed and healthy
oc get hyperconverged -n openshift-cnv
oc get kubevirt   -n openshift-cnv
oc get pods       -n openshift-cnv

# virtctl - NOT installed by oc. Get it from:
#   Virtualization -> Overview -> virtctl -> Download
oc get consoleclidownload virtctl-clidownloads-kubevirt-hyperconverged -o yaml
virtctl version
```

Full details, including RBAC roles and `virtctl` command coverage, in
[`docs/00-prerequisites.md`](docs/00-prerequisites.md).

---

## Environment setup

Every example assumes three shell variables:

```bash
export NS=vms
export VM=web-01
export SERVER=$(oc whoami --show-server)
```

For the raw REST examples you also need authentication — see
[`docs/04-rest-api.md`](docs/04-rest-api.md):

```bash
# Bearer token
export TOKEN=$(oc whoami -t)

# ...or extract the client certificate from your kubeconfig
OUT=$(mktemp -d)
oc config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d > "$OUT/ca.crt"
oc config view --raw --minify -o jsonpath='{.users[0].user.client-certificate-data}'      | base64 -d > "$OUT/client.crt"
oc config view --raw --minify -o jsonpath='{.users[0].user.client-key-data}'              | base64 -d > "$OUT/client.key"
```

---

## Discover your cluster's values

The manifests use placeholders. Find the real values with:

```bash
# Cluster apps domain
oc get ingress.config cluster -o jsonpath='{.spec.domain}'; echo

# Golden images (boot sources) - do they actually work?
oc get datasources -n openshift-virtualization-os-images

# Instance types (vCPU / RAM shapes)
oc get virtualmachineclusterinstancetypes

# OS preferences
oc get virtualmachineclusterpreferences

# Storage classes and their capabilities
oc get storageclass
oc get storageprofile -o custom-columns=\
NAME:.metadata.name,CLONE:.status.cloneStrategy,SNAPCLASS:.status.snapshotClass

# Networks available to VMs
oc get network-attachment-definitions -A

# Compute servers
oc get nodes -o custom-columns=\
NAME:.metadata.name,ROLES:.metadata.labels.node-role\.kubernetes\.io/worker,\
CPU:.status.capacity.cpu,MEM:.status.capacity.memory
```

Placeholders used throughout:

| Placeholder | Meaning |
| --- | --- |
| `<NAMESPACE>` / `$NS` | namespace holding your VMs |
| `<VM_NAME>` / `$VM` | the virtual machine name |
| `<CLUSTER_DOMAIN>` | `spec.domain` of `ingresses.config/cluster` |
| `<NODE_NAME>` | a schedulable node |
| `<STORAGE_CLASS>` | e.g. `nfs-csi`, `ocs-storagecluster-ceph-rbd` |
| `<NAD_NAME>` | a `NetworkAttachmentDefinition`, e.g. `vlan-60` |

---

## Validate a manifest before applying it

Server-side dry run runs the real admission webhooks and defaulting:

```bash
oc apply --dry-run=server -f 01-deploy/rhel9-full-example.yaml
```

```bash
curl -s $CURL -X POST -H 'Content-Type: application/yaml' \
  "$SERVER/apis/kubevirt.io/v1/namespaces/$NS/virtualmachines?dryRun=All" \
  --data-binary @01-deploy/rhel9-full-example.yaml
```

---

## Three warnings worth reading before you start

**1. Windows boot sources are placeholders.** Red Hat cannot redistribute Windows
media, so `win10`, `win11`, `win2k16`, `win2k19`, `win2k22` and `win2k25`
`DataSource` objects exist while their backing PVCs do not:

```
type: Ready  status: "False"  reason: NotFound  message: PVC not found
```

A Windows VM created from a broken boot source will fail. Populate it first — see
[`docs/01-boot-sources.md`](docs/01-boot-sources.md).

**2. `oc delete vm` can destroy the disk.** If a VM's PVC has an
`ownerReference` back to the `VirtualMachine`, garbage collection takes the disk
with it. Clusters built by migration tooling commonly do this. Inspect first:

```bash
oc get pvc <pvc> -n $NS -o jsonpath='{.metadata.ownerReferences}{"\n"}'
```

Use `?propagationPolicy=Orphan` to delete a VM and keep its disks — see
[`04-delete/`](04-delete/).

**3. Some features are installed but gated off.** `VirtualMachineBackup` exists
as a CRD yet every request is rejected until the alpha `incrementalBackup` gate
is enabled. The `priority` field on a migration needs `MigrationPriorityQueue`.
See [`docs/05-feature-gates.md`](docs/05-feature-gates.md).

---

## License

Not yet chosen — add one before distributing.
