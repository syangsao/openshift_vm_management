# 03 — Add a VLAN / subnet to the compute pool

A VM's network lives in a **`NetworkAttachmentDefinition` (NAD)** — a plain
cluster object Terraform reconciles via `kubectl_manifest`. This is the cleanest
case in the whole section: the "task" *is* a CR, so there is no orchestration
glue at all.

The two shapes mirror [`../api/docs/03-networking-and-storage.md`](../api/docs/03-networking-and-storage.md)
exactly:

| Shape | Who hands the VM its address | Use when |
| --- | --- | --- |
| **a) OVN localnet** (`topology: localnet`) | whatever serves DHCP **on the VLAN** | The VM must be a first-class citizen on the physical LAN (a real VLAN on the switch) |
| **b) macvlan + host-local IPAM** | the **cluster**, from `ipam.subnet` | You just need VMs on a specific subnet, cluster-managed, no switch VLAN required |

## The two resources

- `kubectl_manifest.nad_localnet` — the OVN localnet NAD. `netAttachDefName`
  must point at an NAD in the **`default`** namespace (OVN's requirement), so the
  module takes `nad_namespace` (default `default`) for that reference.
- `kubectl_manifest.nad_macvlan` — the macvlan NAD with `host-local` IPAM over a
  `192.0.2.0/24` example range (the repo's portable placeholder range). `master`
  is the physical interface on each compute node that carries the VLAN.

## Attaching a VM

The NAD does nothing until a VM references it (`multus: networkName:` +
`bridge: {}` on an interface) — that half of the task is the VM object itself,
see [`../api/01-deploy/`](../api/01-deploy/) and the networking doc for the exact
`interfaces`/`networks` YAML. Pinning a MAC is also done on the VM
(`macAddress`), not here.

## Caveats

- The **switch-side VLAN** (port config, the OVN `localnet` patch port) is
  physical infrastructure Terraform does not model; the localnet NAD assumes the
  VLAN already exists on the network.
- A NAD in namespace `X` is addressed as `X/<name>`; keep the NAD namespace and
  the `netAttachDefName` in sync when you move things around.

## Validation

`terraform init` + `terraform validate` pass. The NAD JSON is byte-identical in
structure to what `api/` applied with `oc apply --dry-run=server`, so the CRs are
cluster-validated by construction.

## Related

- [`../api/docs/03-networking-and-storage.md`](../api/docs/03-networking-and-storage.md)
- [`../api/01-deploy/`](../api/01-deploy/) — the VM that consumes the NAD
