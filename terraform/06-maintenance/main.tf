# Updates and maintenance. Every task is opt-in via variables, so a bare
# plan/apply is a no-op.
#
#   - OCP upgrade:  patch the cluster-scoped ClusterVersion (gated)
#   - CNV bump:     bump the OLM Subscription channel (declarative, always on)
#   - Node window:  cordon / uncordon / drain  (gated, side-effect)
#   - Migration:    one-shot oc migrate       (gated, side-effect)

terraform {
  required_version = ">= 1.5"
  required_providers {
    kubectl = { source = "alekc/kubectl", version = ">= 2.4.1, < 3.0.0" }
    null    = { source = "hashicorp/null", version = ">= 3.2.0" }
  }
}

provider "kubectl" {
  config_path = var.kubeconfig
}

variable "kubeconfig" {
  type    = string
  default = "~/.kube/config"
}

# ---- (a) OCP upgrade: set the desired version on the ClusterVersion.
#      Gated off by default: unconditionally managing spec.desired.version would
#      pin the cluster to the last value you set. ----
variable "manage_ocp_upgrade" {
  type    = bool
  default = false
}
variable "ocp_version" {
  type    = string
  default = "4.22.1"
}
resource "kubectl_manifest" "cluster_version" {
  count = var.manage_ocp_upgrade ? 1 : 0
  yaml_body = yamlencode({
    apiVersion = "config.openshift.io/v1"
    kind       = "ClusterVersion"
    metadata   = { name = "version" }
    spec = {
      desired = { version = var.ocp_version }
    }
  })
}

# ---- (b) CNV operator upgrade: bump the OLM Subscription channel. OLM
#      reconciles the operator; VMs keep running through the upgrade. ----
variable "cnv_channel" {
  type    = string
  default = "stable"
}
resource "kubectl_manifest" "cnv_subscription" {
  yaml_body = yamlencode({
    apiVersion = "operators.coreos.com/v1"
    kind       = "Subscription"
    metadata   = { name = "rhcs-virtualization-operator", namespace = "openshift-operator-marketplace" }
    spec = {
      name            = "rhcs-virtualization-operator"
      channel         = var.cnv_channel
      package         = "rhcs-virtualization-operator"
      source          = "redhat-operators"
      sourceNamespace = "openshift-operator-marketplace"
    }
  })
}

# ---- (c) Node maintenance window: cordon | uncordon | drain.
#      A drain live-migrates the node's VMs (default evictionStrategy is
#      LiveMigrate). Set maintain_node = "" to skip. ----
variable "maintain_node" {
  type    = string
  default = ""
}
# cordon | uncordon | drain
variable "action" {
  type    = string
  default = "cordon"
}
resource "null_resource" "node_maint" {
  count    = var.maintain_node != "" ? 1 : 0
  triggers = { node = var.maintain_node, action = var.action }
  provisioner "local-exec" {
    command     = <<-EOT
      set -e
      node="${var.maintain_node}"
      case "${var.action}" in
        cordon)   oc adm cordon "$node" ;;
        uncordon) oc adm uncordon "$node" ;;
        drain)    oc adm drain "$node" --ignore-daemonsets --delete-emptydir-data ;;
        *) echo "action must be cordon|uncordon|drain, got '${var.action}'"; exit 1 ;;
      esac
    EOT
    interpreter = ["/bin/bash", "-c"]
  }
}

# ---- (d) One-shot live migration of a single VM. Set vm_name = "" to skip. ----
variable "vm_name" {
  type    = string
  default = ""
}
variable "ns" {
  type    = string
  default = "vms"
}
resource "null_resource" "migrate_vm" {
  count    = var.vm_name != "" ? 1 : 0
  triggers = { vm = var.vm_name, ns = var.ns }
  provisioner "local-exec" {
    command     = "oc migrate ${var.vm_name} -n ${var.ns} --wait"
    interpreter = ["/bin/bash", "-c"]
  }
}
