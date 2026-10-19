# 06 — Updates and maintenance

The recurring "keep it current" tasks: OCP cluster upgrades, CNV operator
channel bumps, node maintenance windows, and one-off live migrations. Each is a
small unit, and the module is **opt-in per task** — nothing fires until you set
the variable that turns it on, so a bare `plan`/`apply` is a no-op.

| Task | Unit | How it works |
| --- | --- | --- |
| OCP upgrade | `kubectl_manifest.cluster_version` (gated) | Patches `spec.desired.version` on the cluster-scoped `ClusterVersion` named `version`. The CVO then does the actual upgrade; Terraform only sets the desired target |
| CNV channel bump | `kubectl_manifest.cnv_subscription` (always) | Bumps the OLM `Subscription` `channel`; OLM reconciles the operator to the new version |
| Node maintenance | `null_resource.node_maint` (gated) | `oc adm cordon` / `uncordon` / `drain` — a drain live-migrates the node's VMs (the cluster default `evictionStrategy` is `LiveMigrate`) |
| Manual live migration | `null_resource.migrate_vm` (gated) | `oc migrate <vm> -n <ns>` — the same one-shot as the api/ section, just driven by Terraform |

## Gating

- `manage_ocp_upgrade = true` creates the `ClusterVersion` manifest. It is off by
  default on purpose: unconditionally managing `spec.desired.version` would pin
  the cluster to whatever you last set and surprise an upgrade.
- `maintain_node` / `vm_name` default to `""`; an empty value means the resource
  is not created.

## Notes

- An OCP upgrade is a **rolling** operation: after `apply`, watch it with
  `oc get clusterversion`. Terraform's job ends when the desired version is set,
  not when the rollout completes — add a `local-exec` wait on
  `oc get clusterversion -o jsonpath='{.status.conditions[?(@.type=="Progressing")].message}'`
  if you need the gate.
- Node maintenance is the mirror image of [`05-node-removal/`](../05-node-removal/):
  cordon → drain → (work) → uncordon, with the drain migrating VMs automatically.
  To *stop* a VM instead of migrating it during a drain, set
  `evictionStrategy: None` on the VM first.
- A CNV channel bump is the operator-level analog of the OCP upgrade: the
  operator pod changes, and your VMs keep running through it (VMs are not
  restarted by an operator upgrade).

## Validation

`terraform init` + `terraform validate` pass. The gated units are schema-
checked; the imperative ones only make sense `apply`-ed against a live cluster.

## Related

- [`../api/02-lifecycle/`](../api/02-lifecycle/) — node maintenance, live migration
- [`05-node-removal/`](../05-node-removal/) — the permanent variant of a maintenance window
