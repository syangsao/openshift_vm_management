# openshift_vm_management

Managing virtual machines on **OpenShift Virtualization** — practical, validated
examples organised by the tooling used to drive the platform.

The repository is laid out as a set of independent sections. Each section is
self-contained and can be read without the others.

---

## Sections

| Section | Approach | Status |
| --- | --- | --- |
| [`api/`](api/) | Direct API — CRD objects, REST calls, `oc` invocations | Complete |
| `terraform/` | Declarative infrastructure-as-code | Planned |

### `api/` — direct API usage

Everything you can do to a VM by talking to `kube-apiserver`: the CRD objects you
submit, the REST requests they become, and the `oc` commands that wrap them.

| Path | Covers |
| --- | --- |
| [`api/docs/`](api/docs/) | API surface, boot sources, networking, storage, raw REST, feature gates |
| [`api/01-deploy/`](api/01-deploy/) | Deploy RHEL 9, RHEL 10, Windows 2025 — subnet/IP, OS disk, data disks, vCPU, RAM, OS version, affinity/anti-affinity |
| [`api/02-lifecycle/`](api/02-lifecycle/) | Power operations, live migration to another compute server, node maintenance |
| [`api/03-scaling/`](api/03-scaling/) | Increase/decrease vCPU, RAM, disks, NICs — hot-plug where supported |
| [`api/04-delete/`](api/04-delete/) | Delete a VM **and** its ancillary components, safely |
| [`api/05-operators/`](api/05-operators/) | Other lifecycle controllers: pools, clones, snapshots, backups, exports |

Start here → [`api/README.md`](api/README.md)

---

## Scope and conventions

- **Target platform:** OpenShift Container Platform 4.22 with OpenShift
  Virtualization (KubeVirt `v1`). Other versions will differ in field-level
  details — always confirm with `oc explain`.
- **Validated, not hypothetical.** Every manifest in `api/` is checked with
  `oc apply --dry-run=server` against a live cluster, which runs the real
  admission webhooks and defaulting. Where a schema-valid object is still
  *rejected* — a feature gate is off, or a runtime precondition is unmet — that
  is documented inline in the manifest rather than hidden.
- **Portable values.** All manifests use placeholders (`<NAMESPACE>`,
  `<STORAGE_CLASS>`, `example.com`) and documentation IP ranges. Nothing in this
  repository is tied to a specific cluster.
- **No wrapper scripts.** Each task is expressed as the API request it actually
  is, so the examples translate directly into whatever language or automation
  you use.

---

## License

Not yet chosen — add one before distributing.
