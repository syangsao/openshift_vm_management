# Add a Pure Storage FlashArray to the cluster as block storage for VMs.
#
# The CSI integration ships as a Helm chart, so this is a genuine declarative
# unit: Terraform tracks the release in state and can upgrade/rollback it.
# The chart deploys the CSI operator/driver and creates the StorageClass(es)
# from the values below.

terraform {
  required_version = ">= 1.5"
  required_providers {
    helm = { source = "hashicorp/helm", version = ">= 3.0.0" }
  }
}

provider "helm" {
  kubernetes = {
    config_path = var.kubeconfig
  }
}

variable "kubeconfig" {
  type    = string
  default = "~/.kube/config"
}
variable "ns" {
  type    = string
  default = "pure"
}
# "" = latest chart version
variable "chart_version" {
  type    = string
  default = ""
}
variable "sc_name" {
  type    = string
  default = "pure-flasharray"
}

variable "pure" {
  type = object({
    endpoint = string # "https://flasharray.example.com:8081"
    token    = string # Pure1 API token
    san      = string # FlashArray name
  })
  default = {
    endpoint = "https://flasharray.example.com:8081"
    token    = "changeme"
    san      = "flasharray"
  }
}

# NOTE: confirm the exact values keys for your chart release with
#   helm show values pure-csi --repo https://purestorage.github.io/helm-charts
# This file is a starting skeleton, not a pinned schema.
resource "helm_release" "pure_csi" {
  name             = "pure-operator"
  namespace        = var.ns
  create_namespace = true
  repository       = "https://purestorage.github.io/helm-charts"
  chart            = "pure-csi"
  version          = var.chart_version
  values = [yamlencode({
    platform = "openshift"
    flashArray = [{
      endpoint = var.pure.endpoint
      apiToken = var.pure.token
      san      = var.pure.san
      storageClasses = [{
        name                 = var.sc_name
        provisioner          = "pure"
        accessModes          = ["ReadWriteMany"] # RWX => live-migration-safe DataVolumes
        allowVolumeExpansion = true
        parameters = {
          snapshotAction   = "Copy"
          provisioningType = "block"
        }
      }]
    }]
  })]
}
