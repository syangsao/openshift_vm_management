# Terraform — declarative infrastructure-as-code

The same seven tasks as the [`api/`](../api/) section, expressed as **Terraform
modules**. Target: OCP **4.22** / OpenShift Virtualization **v1**. Every module is
self-contained (its own `terraform{}` block, providers, variables) and validated
with `terraform validate`.

## The thing to understand first

Terraform **does not install OpenShift, and it does not install RHEL**. It
*orchestrates* them. A module has two kinds of units, and mixing the two up is
the whole trap:

| Unit | Terraform resource | What it really is |
| --- | --- | --- |
| **Declarative CR** | `kubectl_manifest` / `helm_release` | A real cluster object Terraform can reconcile — the same object `api/` applies with `oc apply`. Terraform tracks it in state and converges it. |
| **Orchestration side-effect** | `null_resource` + `local-exec` | A one-way action Terraform *runs* but does not own: `oc adm drain`, `openshift-install`, a Red Hat case API call. Terraform can't "un-drain" a node or "un-open" a ticket, so these are imperative by nature. |
| **BMC / Redfish** | `redfish_*` | Hardware-level control (boot mode, power). This is the only layer Terraform reaches *below* the OS. |

So read each module as a **pipeline**, not a flat object list. The four layers,
outermost to innermost, are:

```
  0. Bare metal (BMC/Redfish: boot source, power)   ->  01-rhel
  1. Guest OS (PXE/kickstart installs RHEL)          ->  01-rhel  (driven, not owned)
  2. OpenShift (openshift-install / Machine API)     ->  02-cluster
  3. CNV + node roles + ACM                           ->  02-cluster
  4. Networking / storage / lifecycle / maintenance   ->  03..07
```

Terraform "owns" only the control-plane state (the CRs). Everything below a
running cluster — the OS install, the OCP bootstrap, the node objects the
kubelet creates — is *driven* through `local-exec` / the Redfish provider. Node
`Node` objects are **cluster-owned** (created by the kubelet); Terraform never
"creates" one, it labels or deletes the node's `Machine`/`BareMetalHost` and the
API removes the node.

## Contents

| Path | Covers |
| --- | --- |
| [`docs/00-prerequisites.md`](docs/00-prerequisites.md) | Terraform version, the four providers, credentials, assumptions, how to run a module |
| [`01-rhel/`](01-rhel/) | Provision a bare-metal server: Redfish → PXE → RHEL 9, wait for OS |
| [`02-cluster/`](02-cluster/) | Install CNV on an existing OCP cluster; compute / controller / ACM node roles; new-cluster bootstrap |
| [`03-networking/`](03-networking/) | Add a VLAN / subnet as a `NetworkAttachmentDefinition` (OVN localnet, macvlan+host-local) |
| [`04-storage/`](04-storage/) | Add a Pure Storage FlashArray as CSI; RWX storage class for live-migration-safe DataVolumes |
| [`05-node-removal/`](05-node-removal/) | Remove a server: migrate → cordon/drain → delete `Machine`/`BareMetalHost` → decommission BMC |
| [`06-maintenance/`](06-maintenance/) | OCP upgrade, CNV/ACM channel bumps, node cordon/drain, manual live migration |
| [`07-support/`](07-support/) | Open a Red Hat support case via the Customer Portal / Case Management API |

## Provider matrix

| # | Task | Provider(s) | Resource(s) |
| --- | --- | --- | --- |
| 01 | Install RHEL on bare metal | `dell/redfish` | `redfish_boot_source_override`, `redfish_power`, `null_resource` (wait for OS) |
| 02 | Install CNV + node roles + ACM | `alekc/kubectl`, `hashicorp/null` | `kubectl_manifest` (Subscription, HyperConverged, MultiClusterHub); `null_resource` (node labels, OCP bootstrap) |
| 03 | Add a VLAN / subnet | `alekc/kubectl` | `kubectl_manifest` (NetworkAttachmentDefinition) |
| 04 | Add Pure Storage | `hashicorp/helm`, `alekc/kubectl` | `helm_release` (pure-csi), `kubectl_manifest` (StorageClass) |
| 05 | Remove a server | `alekc/kubectl`, `hashicorp/null`, `dell/redfish` | `null_resource` (migrate, drain, delete Machine/BMO), `redfish_power` (off) |
| 06 | Updates / maintenance | `alekc/kubectl`, `hashicorp/null` | `kubectl_manifest` (ClusterVersion, Subscription channel), `null_resource` (cordon/drain, migrate) |
| 07 | Open a Red Hat case | `hashicorp/null` | `null_resource` + `local-exec` (case API) |

The `alekc/kubectl` provider is the same one Red Hat's own OpenShift-Virt
Terraform example uses; `hashicorp/helm` is the standard chart driver;
`hashicorp/null` is for side-effects; `dell/redfish` is the only provider that
reaches the hardware layer.

## Conventions

- **Portable values are `variable` blocks** — namespaces, node names, IP ranges
  (`192.0.2.0/24`), endpoints, tokens. Nothing machine-specific is hard-coded in
  the resources.
- **One `main.tf` per task** (mirrors `api/`'s one-file-per-task pattern): the
  `terraform{}`, `provider{}`, `variable{}`, and `resource{}` blocks all live in
  a single file. No split-out `versions.tf` / `variables.tf`.
- **Validation** = `terraform init` + `terraform validate` (schema check, runs
  with no cluster) and `terraform fmt -check`. The CRs are the *same objects*
  `api/` already validated with `oc apply --dry-run=server`, so they are as
  cluster-validated as the `api/` section. The `null_resource`/`redfish`/`helm`
  units are schema-validated but only `plan`/`apply` against a live target.
- **`wait_for` is kept out of the examples.** `alekc/kubectl`'s `wait_for` field
  name (`key` vs `path`) varies across versions and risks a `terraform validate`
  failure; the CRs here are validated by construction instead. Add a `wait_for`
  block yourself where a status field exists (e.g. a VirtualMachine's
  `status.printableStatus` = `Running`).

## New cluster vs joining an existing one

| | What Terraform drives | Layers |
| --- | --- | --- |
| **New cluster** | Redfish → RHEL (01), then the OCP bootstrap (`openshift-install` / assisted / `BareMetalHost`+`Machine`), then CNV + roles (02) | 0 → 3 |
| **Join existing** | Redfish → RHEL (01), register the node as a `BareMetalHost`/`Machine` (or let the node auto-join), then apply the node role labels + CNV (02) | 0 → 1, 3 |

On a user-provisioned cluster the scaling unit is a `Machine` (Cluster API) and,
for metal, a `BareMetalHost` (Bare Metal Operator). Control-plane node scaling
in particular is a **cluster-level operation** — on most deployments it is done
with `openshift-install` or the assisted service, not by deleting a `Machine` —
so `02-cluster` models it as a `local-exec` step and the README explains both
paths rather than inventing a declarative CR for it.

## Related

- [`api/`](../api/) — the same tasks as raw objects and single imperative calls
- [`../README.md`](../README.md) — repository overview
