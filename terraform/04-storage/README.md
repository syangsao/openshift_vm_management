# 04 — Add a Pure Storage FlashArray to the cluster

Attach a FlashArray as block storage for VMs: install the **Pure Storage CSI
driver** via its Helm chart, which in turn deploys the CSI operator/driver and
creates the **StorageClass** the VMs' `DataVolume`s use.

## Why Helm for this one

The CSI integration ships as a Helm chart (`pure-csi` from
`https://purestorage.github.io/helm-charts`), not as a single CR — so
`hashicorp/helm` is the natural Terraform unit here. The `helm_release` is a
genuine declarative unit: Terraform tracks the release in state and can
`upgrade`/`rollback` it, which is more than a one-shot `oc apply`.

## The values, honestly

The chart's `values.yaml` layout changes between releases (the
`flashArray` entry's keys, and the provisioner name the chart registers, in
particular). This module supplies:

| Value | Meaning |
| --- | --- |
| `platform: openshift` | chart targets OpenShift (sets up the operator's namespaces etc.) |
| `flashArray[]` | one entry per array: `endpoint` (`https://<fqdn>:8081`), `apiToken` (Pure1 token), `san` (array name), plus its `storageClasses[]` |
| `storageClasses[].accessModes: ["ReadWriteMany"]` | **RWX is the whole point** — CNV DataVolumes need `ReadWriteMany` for live migration to work; a block-mode RWX PVC is what makes a migrated VM keep its storage |

Confirm the exact key names for your chart release with `helm show values
<chart> --version <v> --repo https://purestorage.github.io/helm-charts` before
applying; treat this file as a starting skeleton.

## The StorageClass

The chart emits the StorageClass(es) from the values above. If you manage the
StorageClass yourself (e.g. the chart version does not support that), the
declarative object is:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata: { name: pure-flasharray }
provisioner: <driver-provisioner-from-the-chart>
allowVolumeExpansion: true
reclaimPolicy: Delete
```

## DataVolumes on top

Creating the actual VM storage is a VM task, not a cluster task — see
[`../api/01-deploy/`](../api/01-deploy/) for `DataVolume`/`PVC` against this
storage class. RWX + `allowVolumeExpansion` together give you both live
migration and in-guest filesystem expansion.

## Validation

`terraform init` + `terraform validate` pass (the `helm_release` schema is
checked; chart contents are only fetched on `plan`/`apply`). A live `apply`
needs a reachable FlashArray endpoint and the API token.

## Related

- [`../api/docs/03-networking-and-storage.md`](../api/docs/03-networking-and-storage.md) — storage for VMs
- [`../api/01-deploy/`](../api/01-deploy/) — `DataVolume` objects consuming the class
