# Boot sources (golden images / "marketplace images")

On OpenShift Virtualization the equivalent of a marketplace image is a
**boot source**: a `DataSource` in the `openshift-virtualization-os-images`
namespace that points at a `PersistentVolumeClaim` holding a prepared disk image.

```
DataSource (openshift-virtualization-os-images/rhel9)
      |
      +-- spec.source.pvc.name --> PVC rhel9-<hash>   (created + refreshed by a DataImportCron)
```

## Inspect what you have

```bash
oc get datasources -n openshift-virtualization-os-images
oc get dataimportcrons -n openshift-virtualization-os-images
```

## Verify every boot source is actually usable

A `DataSource` can exist while its backing PVC does not. Always check:

```bash
oc get datasources -n openshift-virtualization-os-images -o json | \
  python3 -c '
import json,sys,subprocess
d=json.load(sys.stdin)
pvc={p.split()[0] for p in subprocess.run(
    ["oc","get","pvc","-n","openshift-virtualization-os-images","--no-headers"],
    capture_output=True,text=True).stdout.splitlines()}
for i in d["items"]:
    src=i["spec"].get("source",{})
    kinds=list(src)
    name=src.get(kinds[0],{}).get("name") if kinds else None
    print(f"{i[\"metadata\"][\"name\"]:18} pvc={str(name):32} {\"OK\" if name in pvc else \"*** MISSING ***\"}")
'
```

Or read the condition straight off the object:

```bash
oc get datasource win2k25 -n openshift-virtualization-os-images \
  -o jsonpath='{.status.conditions[0].reason}: {.status.conditions[0].message}{"\n"}'
```

## Linux images

RHEL, CentOS Stream and Fedora images are **automatic**. A `DataImportCron`
imports them from `registry.redhat.io` on a schedule (default `43 3/12 * * *`,
i.e. every 12 hours) and re-points the `DataSource` at the newest PVC.

```bash
oc get dataimportcron rhel9-image-cron -n openshift-virtualization-os-images \
  -o jsonpath='{.spec.managedDataSource} {.spec.schedule}{"\n"}'
```

Because the cluster's pull secret carries the RHEL entitlement, these just work.

## Windows images

Red Hat **cannot redistribute** Windows media. The SSP Operator creates
placeholder `DataSource` objects for `win10`, `win11`, `win2k16`, `win2k19`,
`win2k22`, `win2k25` — and no `DataImportCron`. Their PVCs do not exist until an
administrator populates them, and the `DataSource` sits at:

```
type:    Ready
status:  "False"
reason:  NotFound
message: PVC not found
```

**A Windows VM created from a broken boot source will fail.** Populate it first.

### Populate a Windows boot source from an ISO

```bash
NS=openshift-virtualization-os-images
CLUSTER_DOMAIN=$(oc get ingress.config cluster -o jsonpath='{.spec.domain}')

virtctl image-upload dv win2k25 \
  --namespace "$NS" \
  --size=30Gi \
  --image-path=/path/to/windows-server-2025.iso \
  --storage-class=<STORAGE_CLASS> \
  --uploadproxy-url="https://cdi-uploadproxy-${CLUSTER_DOMAIN}" \
  --insecure \
  --force-bind
```

The `DataSource` named `win2k25` already points at the PVC name `win2k25`, so it
flips to `Ready=True` by itself once the PVC exists.

### Populate from an HTTP source instead

```yaml
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: win2k25
  namespace: openshift-virtualization-os-images
spec:
  source:
    http:
      url: https://internal-mirror.example.com/iso/windows-server-2025.iso
  pvc:
    accessModes: [ReadWriteMany]
    resources:
      requests:
        storage: 30Gi
    storageClassName: <STORAGE_CLASS>
    volumeMode: Block
```

## Importing your own image

Any other guest OS: import it and (optionally) register a `DataSource` so it
shows up as a boot source in the console.

```yaml
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: my-golden-image
  namespace: openshift-virtualization-os-images
spec:
  source:
    registry:
      url: docker://quay.io/containerdisks/fedora:latest
  pvc:
    accessModes: [ReadWriteMany]
    resources:
      requests:
        storage: 20Gi
    storageClassName: <STORAGE_CLASS>
```

Supported `source` kinds: `http`, `s3`, `registry`, `pvc`, `snapshot`,
`upload`, `blank`, `imageio`.

## Cloning a boot source for a VM (validated on OCP 4.22 / CNV 4.22.12)

The `DataVolume` is the unit of import. Two patterns:

### From a `DataSource` in `openshift-virtualization-os-images`

This is what the console does when you pick a boot source. The `dataVolumeTemplate`
in the VM spec references the `DataSource` by name, and CDI clones it at creation time:

```yaml
# In the VirtualMachine spec
spec:
  dataVolumeTemplates:
    - metadata:
        name: root
      spec:
        source:
          pvc:
            name: centos-stream9-19948c490936   # the backing PVC of the DataSource
            namespace: openshift-virtualization-os-images
        pvc:
          accessModes: [ReadWriteMany]
          resources:
            requests:
              storage: 35Gi                      # MUST be >= source size
          storageClassName: <STORAGE_CLASS>
```

### Standalone `DataVolume` (for manual / scripted imports)

```yaml
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: my-vm-root
  namespace: vms
spec:
  source:
    pvc:
      name: centos-stream9-19948c490936
      namespace: openshift-virtualization-os-images
  pvc:
    accessModes: [ReadWriteMany]
    resources:
      requests:
        storage: 35Gi
    storageClassName: <STORAGE_CLASS>
```

```bash
oc wait --for=jsonpath='{.status.phase}'=Succeeded dv/my-vm-root -n vms --timeout=15m
```

### Pitfalls (validated on OCP 4.22)

**Target size must be >= source size.** CDI rejects the clone at admission if the
target `storage` request is smaller than the source PVC:

```
CloneValidationFailed: target resources requests storage size is smaller
than the source 10737418240 < 34144990004
```

Check the source size first:

```bash
oc get pvc centos-stream9-<hash> -n openshift-virtualization-os-images \
  -o jsonpath='{.spec.resources.requests.storage}'
```

**The `DataVolume` spec is immutable.** Once created, you cannot patch the source.
Delete and recreate:

```bash
oc delete dv my-vm-root -n vms --wait=false
# fix the manifest, then
oc apply -f my-dv.yaml
```

**Smart clone uses VolumeSnapshot under the hood.** When the storage class supports
snapshots (CSI with a `VolumeSnapshotClass`), CDI takes a snapshot of the source PVC
and restores it into the target. The DV phase sequence is:

```
Pending → SnapshotForSmartCloneInProgress → CloneFromSnapshotSourceInProgress → Succeeded
```

This is fast (snapshot is copy-on-write) but requires the `VolumeSnapshotClass` to be
registered in the storage profile. On NFS-CSI this works out of the box.

**HTTP sources can 404 silently.** If the URL is wrong, the DV enters a retry loop
with `Unable to connect to http data source: expected status code 200, got 404`.
The DV does not fail permanently — it keeps retrying. Check events:

```bash
oc get events -n vms --field-selector involvedObject.name=my-vm-root
```

## DataSource vs DataVolume vs PVC

| Object | Role |
| --- | --- |
| `DataSource` | A stable, versionable *pointer* to an image. What the console lists. |
| `DataVolume` | A CDI-managed import/clone job that produces a PVC. |
| `PersistentVolumeClaim` | The actual disk. What the VM mounts. |

A `DataSource` lets a `dataVolumeTemplate` clone the image at VM creation time,
so the boot source is never modified by the guest.
