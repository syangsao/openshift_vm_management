# 05 — Remove a server from the OCP-Virt cluster

Take one node out of the cluster: move its VMs, drain it, tell the Machine API
to scale it down, then decommission the BMC. **Order matters** and the module
expresses that as a dependency chain:

```
 migrate VMs (live)
     → cordon + drain            (drain re-migrates anything left)
     → delete Machine / BareMetalHost   (Machine API removes the node)
     → BMC power off             (decommission hardware)
```

## Why all of this is `null_resource` + `local-exec`

There is no "node deletion" CR. `Node` objects are **cluster-owned** — the
kubelet creates them and the Machine API tears them down when you delete the
node's `Machine` (and, on user-provisioned metal, its `BareMetalHost`). Terraform
therefore *drives `oc`* at each step and chains them with `depends_on` — it does
not, and cannot, "delete a node" as a declarative object. `terraform destroy`
will **not** run these steps backwards; it only tears down the declarative
resources (the Redfish power resource's destroy is a no-op). Treat an `apply`
here as a one-way procedure.

## The steps

| Step | Command | Notes |
| --- | --- | --- |
| 1. Pre-check | list VMs whose `LiveMigratable` condition is not `True` on the node, and fail | A non-migratable VM blocks the drain (see the api/02-lifecycle node-maintenance section) |
| 2. Migrate | `oc migrate <vmi> -n <ns> --wait` for every VMI with `status.nodeName = <node>` | Enumerated from VMI status, not a label — `nodeName` is a status field |
| 3. Cordon + drain | `oc adm cordon` / `oc adm drain --ignore-daemonsets --delete-emptydir-data` | With `evictionStrategy: LiveMigrate` (the cluster default) the drain itself migrates VMs; `evictionStrategy: None` powers them off instead |
| 4. Scale down | `oc delete machine <node>` + `oc delete baremetalhost <node> -n openshift-metal` | The Machine API removes the `Node` once the Machine is gone |
| 5. Decommission | `redfish_power` `ForceOff` | Only when you supply `bmc` entries for the server |

## Variables

- `node` — the node's FQDN (the `Node` object name).
- `bmc` — optional map (same shape as `01-rhel`'s `servers`) for the server's
  BMC. Leave it empty to skip the power-off step (e.g. re-using the hardware).

## Caveats

- `oc migrate --wait` blocks until the migration completes; a fleet of large VMs
  can make this step slow — that is expected, not a hang.
- If the node's VMs include ones that must *stay* (not be migrated), set
  `evictionStrategy: None` on them first (powers them off instead) — see
  [`../api/02-lifecycle/`](../api/02-lifecycle/).
- Deleting the `Machine` on a *managed* platform scales the machine pool instead;
  the imperative path is the same idea (`oc scale`/provider tooling), just
  different objects.

## Validation

`terraform init` + `terraform validate` pass. Everything here is
schema-validated only — the procedure only makes sense `apply`-ed against a live
cluster.

## Related

- [`../api/02-lifecycle/`](../api/02-lifecycle/) — node maintenance, drain, per-node VM inventory
- [`01-rhel/`](../01-rhel/) — the reverse direction (provision hardware)
