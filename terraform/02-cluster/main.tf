# Install OpenShift Virtualization on a cluster, designate node roles (compute /
# controller / ACM), and (for a NEW cluster) bootstrap OCP itself.
#
#   - CNV + ACM = declarative CRs (kubectl_manifest) Terraform reconciles.
#   - Node labels + OCP bootstrap = side-effects (null_resource), because Node
#     objects are cluster-owned and openshift-install is an imperative installer.

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
variable "ns" {
  type    = string
  default = "openshift-cnv"
}

# ---- (a) Install the CNV operator (OLM Subscription) ----
resource "kubectl_manifest" "cnv_subscription" {
  yaml_body = yamlencode({
    apiVersion = "operators.coreos.com/v1"
    kind       = "Subscription"
    metadata   = { name = "rhcs-virtualization-operator", namespace = "openshift-operator-marketplace" }
    spec = {
      name            = "rhcs-virtualization-operator"
      channel         = "stable"
      package         = "rhcs-virtualization-operator"
      source          = "redhat-operators"
      sourceNamespace = "openshift-operator-marketplace"
    }
  })
}

# ---- (b) Configure CNV (the HyperConverged object) ----
resource "kubectl_manifest" "hyperconverged" {
  depends_on = [kubectl_manifest.cnv_subscription]
  yaml_body = yamlencode({
    apiVersion = "hyperconverged.openshift.io/v1beta1"
    kind       = "HyperConverged"
    metadata   = { name = "kubevirt-hyperconverged", namespace = var.ns }
    spec       = { configuration = {} }
  })
}

# ---- (c) Compute nodes: label them (side-effect; the Node is cluster-owned).
#      VMs pin to them via nodeSelector (see ../api/01-deploy/). ----
variable "compute_nodes" {
  type    = map(string)
  default = {} # e.g. { "worker-0.example.com" = "compute pool member" }
}
resource "null_resource" "label_compute_nodes" {
  for_each = var.compute_nodes
  triggers = { node = each.key }
  provisioner "local-exec" {
    command     = "oc label node ${each.key} node-role.kubernetes.io/compute= --overwrite"
    interpreter = ["/bin/bash", "-c"]
  }
}

# ---- (d) ACM: operator Subscription + hub (or a ManagedCluster for a spoke) ----
resource "kubectl_manifest" "acm_subscription" {
  yaml_body = yamlencode({
    apiVersion = "operators.coreos.com/v1"
    kind       = "Subscription"
    metadata   = { name = "advanced-cluster-management", namespace = "openshift-operator-marketplace" }
    spec = {
      name            = "advanced-cluster-management"
      channel         = "stable-2.13"
      package         = "advanced-cluster-management"
      source          = "redhat-operators"
      sourceNamespace = "openshift-operator-marketplace"
    }
  })
}
resource "kubectl_manifest" "multiclusterhub" {
  depends_on = [kubectl_manifest.acm_subscription]
  yaml_body = yamlencode({
    apiVersion = "hive.openshift.io/v1"
    kind       = "MultiClusterHub"
    metadata   = { name = "cluster-management-hub" }
  })
}

# ---- (e) NEW cluster only: bootstrap OCP itself.
#      This is the one step Terraform genuinely cannot express declaratively; it
#      runs the installer against a prepared ./install-config and blocks until the
#      API is up. Set bootstrap = true for a from-scratch cluster. ----
variable "bootstrap" {
  type    = bool
  default = false
}
resource "null_resource" "ocp_bootstrap" {
  count = var.bootstrap ? 1 : 0
  provisioner "local-exec" {
    command     = "openshift-install create cluster --dir ./install-config && openshift-install wait-for bootstrap-complete --dir ./install-config"
    interpreter = ["/bin/bash", "-c"]
  }
}
