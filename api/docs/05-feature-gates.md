# Feature gates

Several VM API features are installed as CRDs but **refuse every request** until
a feature gate is enabled. The object definition is valid, the API group is
served, and the admission webhook still rejects you. Know which gates you have.

## Check what is enabled

```bash
# KubeVirt-level gates (the ones that matter for live migration)
oc get kubevirt -n openshift-cnv \
  -o jsonpath='{.items[0].spec.configuration.developerConfiguration.featureGates}{"\n"}'

# HyperConverged-level gates
oc get hyperconverged kubevirt-hyperconverged -n openshift-cnv \
  -o jsonpath='{.spec.featureGates}{"\n"}'
```

```bash
curl -s $CURL "$SERVER/apis/kubevirt.io/v1/namespaces/openshift-cnv/kubevirts" \
  | python3 -c "
import json,sys
for k in json.load(sys.stdin)['items']:
    fg=k['spec'].get('configuration',{}).get('developerConfiguration',{}).get('featureGates',[])
    print(k['metadata']['name'], '->')
    for g in fg: print('   ', g)
"
```

A typical 4.22 default set:

```
CPUManager  Snapshot  ExpandDisks  HostDevices  VMExport  KubevirtSeccompProfile
LiveUpdateNADRef  PanicDevices  WithHostModelCPU  HypervStrictCheck
VideoConfig  DecentralizedLiveMigration  HotplugVolumes
```

## Gates that break specific examples in this repository

| Feature | Gate | Phase | Default | Symptom when disabled |
| --- | --- | --- | --- | --- |
| `VirtualMachineBackup` / `…Tracker` | `incrementalBackup` | **alpha** (dev preview) | off | `admission webhook "virtualmachinebackup-validator…" denied the request: IncrementalBackup feature gate not enabled` |
| `VirtualMachineInstanceMigration.spec.priority` | `MigrationPriorityQueue` | alpha | off | `MigrationPriorityQueue feature gate is not enabled in kubevirt resource` |
| VirtualMachineExport | `VMExport` | beta | **on** | — |
| Snapshots / restore | `Snapshot` | beta | **on** | — |
| Hot-plug volumes (`addvolume` subresource) | `HotplugVolumes` | beta | **on** | — |
| Disk expansion | `ExpandDisks` | beta | **on** | — |
| Cross-cluster live migration | `DecentralizedLiveMigration` | beta | **on** | — |

So on a stock cluster the examples that work are: deploy, power, migrate,
resize/hot-plug, delete, clone, snapshot, export, pool. The **backup** examples
need a gate, and the `priority` field on a migration needs a gate.

## Enable a gate

Gates live in two places depending on their level. HyperConverged feature gates
go on the `HyperConverged` CR:

```bash
oc patch hyperconverged kubevirt-hyperconverged -n openshift-cnv --type merge \
  -p '{"spec":{"featureGates":[{"name":"incrementalBackup","state":true}]}}'
```

KubeVirt-level gates (such as `MigrationPriorityQueue`) go on the `KubeVirt` CR:

```bash
oc patch kubevirt kubevirt-kubevirt-hyperconverged -n openshift-cnv --type merge \
  -p '{"spec":{"configuration":{"developerConfiguration":{"featureGates":["MigrationPriorityQueue"]}}}}'
```

> **Be careful.** Patching the `KubeVirt` CR directly can be reverted by the
> HyperConverged Operator on its next reconcile. Prefer the `HyperConverged` CR
> when a gate is exposed there, and check the operator's `featureGates` list:
>
> ```bash
> oc explain hyperconverged.spec.featureGates
> ```

## List the gates the operator knows about

```bash
oc explain hyperconverged.spec.featureGates 2>&1 | grep -oE '^    \* [a-zA-Z]+' | sed 's/.*\* //' | sort
```

Known HyperConverged gates in 4.22:

```
alignCPUs                      enableApplicationAwareQuota
autoResourceLimits             enableCommonBootImageImport
containerPathVolumes           enableManagedTenantQuota
decentralizedLiveMigration     enableMultiArchBootImageImport
declarativeHotplugVolumes      incrementalBackup
deployKubeSecondaryDNS         nonRoot
deployKubevirtIpamController   objectGraph
deployTektonTaskResources      persistentReservation
deployVmConsoleProxy           primaryUserDefinedNetworkBinding
disableMDevConfiguration       videoConfig
downwardMetrics                withHostPassthroughCPU
```

Each has a phase: `alpha` (off by default, can be enabled), `beta` (on by
default, can be disabled), `GA` (always on), `deprecated` (cannot be enabled).

## Confirming a gate took effect

```bash
oc get hyperconverged kubevirt-hyperconverged -n openshift-cnv \
  -o jsonpath='{.status.conditions}' | python3 -m json.tool

# The KubeVirt CR should now list the gate
oc get kubevirt -n openshift-cnv \
  -o jsonpath='{.items[0].spec.configuration.developerConfiguration.featureGates}{"\n"}'
```

The Operator rolls the affected components, which can take several minutes and
may trigger VM live migrations if `workloadUpdateStrategy` includes
`LiveMigrate`.
