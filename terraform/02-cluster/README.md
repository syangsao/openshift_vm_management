# 02 — Install CNV, designate node roles, and (optionally) bootstrap OCP

Bring OpenShift Virtualization up on a cluster and sort the nodes into roles:
**compute**, **controller**, and an **ACM** (Advanced Cluster Management) node.

This is the section that splits between *new* and *existing* clusters:

| | Terraform drives |
| --- | --- |
| **Existing OCP cluster** | the CNV operator (`Subscription`) + `HyperConverged` config, node role labels, the ACM hub |
| **New cluster** | the OCP bootstrap itself (`openshift-install`, or assisted / `BareMetalHost`+`Machine`) *then* everything above |

## What is declarative vs. side-effect

| Resource | Kind | Notes |
| --- | --- | --- |
| `kubectl_manifest.cnv_subscription` | declarative CR | OLM `Subscription` for `rhcs-virtualization-operator` (Red Hat certified CNV) |
| `kubectl_manifest.hyperconverged` | declarative CR | the `HyperConverged` object that configures CNV once the operator is up |
| `kubectl_manifest.acm_subscription` | declarative CR | OLM `Subscription` for `advanced-cluster-management` |
| `kubectl_manifest.multiclusterhub` | declarative CR | the ACM hub (a "hub" cluster); a *managed* (spoke) cluster instead gets an `ManagedCluster` + agent |
| `null_resource.label_compute_nodes` | side-effect | `oc label node ... node-role.kubernetes.io/compute=` — Node objects are cluster-owned, so Terraform drives `oc` rather than "creating" a node |
| `null_resource.ocp_bootstrap` | side-effect (new cluster only) | `openshift-install create cluster` + `wait-for bootstrap-complete` — gated behind `var.bootstrap` |

## Compute node

"Making a node a compute node" has two halves, and only the first is a cluster
object Terraform owns:

1. **Label the node** — `oc label node <node> node-role.kubernetes.io/compute=`
   (a side-effect; the `Node` itself is created by the kubelet).
2. **Pin VMs to it** — the VM's `nodeSelector` / affinity (the declarative half
   lives in [`../api/01-deploy/`](../api/01-deploy/) — the `VirtualMachine` object
   carries the affinity). A VM without affinity lands on any schedulable node;
   with `node-role.kubernetes.io/compute` it stays on the compute pool.

## Controller node

Control-plane node scaling is a **cluster-level operation**, not a CNV one. On a
user-provisioned (bare-metal) cluster the scaling unit is a `Machine` (Cluster
API) and, for metal, a `BareMetalHost` (Bare Metal Operator); on a managed
platform it is the provider's machine pool. In most real deployments control-plane
changes go through `openshift-install` or the assisted service, so this module
models that as a `local-exec` step (`ocp_bootstrap`) and leaves the per-`Machine`
scaling to the same imperative path — inventing a declarative CR for it would be
the kind of overclaim this repo avoids. For a *new* cluster, `openshift-install`
reads an `install-config.yaml` that already names the control-plane hosts.

## Validation

`terraform init` + `terraform validate` pass against the provider schemas. The
CRs are the same objects `api/` validated with `oc apply --dry-run=server`. A live
`terraform apply` needs a kubeconfig with the right RBAC (the CNV/ACM `Subscription`s
land in `openshift-operator-marketplace`; `HyperConverged` in its own namespace).

## Related

- [`../api/01-deploy/`](../api/01-deploy/) — the VM object (carries node affinity)
- [`../api/02-lifecycle/`](../api/02-lifecycle/) — node maintenance / drain
- [`../api/docs/00-prerequisites.md`](../api/docs/00-prerequisites.md)
