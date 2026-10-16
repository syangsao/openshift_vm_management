# Prerequisites

## Cluster

```bash
# OpenShift Virtualization must be installed and healthy
oc get hyperconverged kubevirt-hyperconverged -n openshift-cnv
oc get kubevirt kubevirt-kubevirt-hyperconverged -n openshift-cnv
oc get pods -n openshift-cnv

# The HyperConverged CR is where live migration, eviction and update
# strategies are configured. Inspect it before assuming defaults.
oc get hyperconverged kubevirt-hyperconverged -n openshift-cnv -o jsonpath='{.spec.virtualization}' | python3 -m json.tool
```

Key defaults to be aware of:

```yaml
spec:
  virtualization:
    evictionStrategy: LiveMigrate          # VMs move on node drain
    liveMigrationConfig:
      parallelMigrationsPerCluster: 5
      parallelOutboundMigrationsPerNode: 2
      completionTimeoutPerGiB: 150
    workloadUpdateStrategy:
      workloadUpdateMethods: [LiveMigrate] # VMs migrate on operator upgrade
```

## CLI tools

### oc

```bash
oc version --client
```

### virtctl

`virtctl` is **not** installed by `oc`. It handles power operations, hot-plug,
live migration, console access, image upload and export.

```bash
# Confirm virtctl is exposed for download by the cluster
oc get consoleclidownload virtctl-clidownloads-kubevirt-hyperconverged -o yaml
```

Download from the web console: **Virtualization → Overview → virtctl → Download**.
That is the supported route and always matches your cluster version.

Verify:

```bash
virtctl version
```

The commands used in this repository:

| Command | Purpose |
| --- | --- |
| `virtctl start/stop/restart <vm>` | Power operations |
| `virtctl pause/unpause vm <vm>` | Pause / resume |
| `virtctl migrate <vm>` | Live migrate |
| `virtctl migrate-cancel <vm>` | Cancel a migration |
| `virtctl addvolume / removevolume` | Hot-plug / unplug disks |
| `virtctl console / vnc / ssh <vm>` | Access |
| `virtctl expose vm <vm>` | Create a Service for a VM |
| `virtctl image-upload dv <dv>` | Upload a disk image |
| `virtctl vmexport create/download` | Export a VM, snapshot or PVC |
| `virtctl create vm` | Generate a manifest |

Run `virtctl options` for the full command list, or see
[the CLI reference](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/virtualization/using-the-cli-tools).

## Namespace and permissions

```bash
oc new-project vms
```

OpenShift Virtualization ships aggregated cluster roles:

| Cluster role | Grants |
| --- | --- |
| `kubevirt.io:view` | Read all virtualization resources |
| `kubevirt.io:edit` | Create, modify, delete VMs and access consoles |
| `kubevirt.io:admin` | Full control incl. the `HyperConverged` CR |
| `kubevirt.io:migrate` | Create/delete `VirtualMachineInstanceMigration` objects |

```bash
oc adm policy add-role-to-user kubevirt.io:edit <user> -n vms
```

CI/automation service accounts need the same, plus CDI permissions if they
create DataVolumes.

## Store your cluster values

Copy the template and fill it in — the helper scripts source it:

```bash
cp .cluster-vars.example .cluster-vars   # .cluster-vars is gitignored
```

```bash
# .cluster-vars
export NAMESPACE=vms
export STORAGE_CLASS=nfs-csi
export CLUSTER_DOMAIN=$(oc get ingress.config cluster -o jsonpath='{.spec.domain}')
```
