# Prerequisites

What you need before running any module in this section.

## Terraform

- Terraform **>= 1.5**. Each module pins its own `required_version`, so a single
  binary on your PATH is enough.

## Providers

Four providers are used across the section. `terraform init` downloads them from
`registry.terraform.io` automatically.

| Provider | Source | What it drives here |
| --- | --- | --- |
| `dell/redfish` | `dell/redfish` (>= 1.6) | The only layer below the OS: boot source override (→ PXE) and power on/off of a server's BMC |
| `alekc/kubectl` | `alekc/kubectl` (>= 2.4, < 3.0) | Cluster CRs: OLM `Subscription`, `HyperConverged`, `NetworkAttachmentDefinition`, `ClusterVersion`, `StorageClass` |
| `hashicorp/helm` | `hashicorp/helm` (>= 3.0) | Chart-based installs (Pure Storage `pure-csi`) |
| `hashicorp/null` | `hashicorp/null` (>= 3.2) | Side-effects: `oc adm`, `openshift-install`, `oc migrate`, the Red Hat case API |

`alekc/kubectl` and `hashicorp/helm` both need a kubeconfig pointing at the
target cluster. The `dell/redfish` provider needs BMC credentials. The
`hashicorp/null` units run a shell command, so they need `oc`, `curl`, etc. in
the `local-exec` environment (your local shell, not the cluster).

## Credentials

Gather these and put them in `terraform.tfvars` (never commit that file):

| For | Variable (example) | Notes |
| --- | --- | --- |
| kubectl / helm modules | `kubeconfig = "~/.kube/config"` | Must point at the OCP cluster; the identity needs `cluster-admin` (or the per-resource RBAC) to apply the CRs |
| Redfish / 01, 05 | `servers` / `bmc` map: `endpoint`, `user`, `password`, `ssl_insecure` | iDRAC (or equivalent) BMC address + admin credentials. `ssl_insecure = true` for self-signed iDRAC certs |
| Pure Storage / 04 | `pure`: `endpoint` (`https://flasharray.example.com:8081`), `token` (Pure1 API token), `san` (FlashArray name) | Create the token in the FlashArray UI under *Pure1 API* |
| Red Hat / 07 | `rh_token` (sensitive) | A Red Hat Customer Portal API bearer token (from your RH SSO / Customer Portal API access). The exact base URL and fields must be confirmed against the current Customer Portal Integration Guide — the API shape changes between releases |

## Assumptions

- **OCP 4.22 with OpenShift Virtualization is already present** for modules
  02–07. Only 01 runs *before* there is a cluster.
- **Bare-metal vs nested:** this section targets bare metal (hence the Redfish
  layer). In a nested / dev environment you skip the `redfish_*` resources and
  the RHEL/PXE layer entirely — the CRs in 02–07 are unchanged.
- **The RHEL install itself is external.** 01 points the server at PXE and waits;
  the actual RHEL 9 install is done by your PXE/kickstack (or a kickstart file).
  Terraform does not have a RHEL-installer provider.
- **Node objects are cluster-owned.** Terraform never creates a `Node`. It labels
  nodes and, for removal/scale-down, deletes the node's `Machine`/`BareMetalHost`
  so the Machine API removes the node.

## How to run a module

Every module is self-contained. From inside its directory:

```bash
terraform init            # downloads the providers, writes .terraform/
terraform validate        # schema check — no cluster needed
terraform plan            # requires a live target (kubeconfig / BMC / token)
terraform apply           # converges the declarative CRs, runs the side-effects
```

`terraform plan` and `apply` need the credentials above. `terraform validate`
does not — it only checks that your HCL matches the provider schemas, which is
how this section was checked.
