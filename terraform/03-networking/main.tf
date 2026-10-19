# Add a VLAN / subnet to the compute pool as a NetworkAttachmentDefinition (NAD).
# The "task" IS a cluster object, so this module is pure declarative CRs.
# The shapes mirror ../api/docs/03-networking-and-storage.md exactly.

terraform {
  required_version = ">= 1.5"
  required_providers {
    kubectl = { source = "alekc/kubectl", version = ">= 2.4.1, < 3.0.0" }
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
  default = "vms"
}
variable "network_name" {
  type    = string
  default = "vlan-60"
}
# Namespace the OVN localnet NAD must be referenced as in netAttachDefName
# (OVN requires the referenced NAD to be in `default`).
variable "nad_namespace" {
  type    = string
  default = "default"
}
variable "host_iface" {
  type    = string
  default = "eth1"
}

# a) OVN-Kubernetes localnet: bridges the VLAN straight to the physical network;
#    the VM's address comes from whatever serves DHCP on that VLAN.
resource "kubectl_manifest" "nad_localnet" {
  yaml_body = yamlencode({
    apiVersion = "k8s.cni.cncf.io/v1"
    kind       = "NetworkAttachmentDefinition"
    metadata   = { name = var.network_name, namespace = var.ns }
    spec = {
      config = jsonencode({
        cniVersion       = "0.3.1"
        name             = var.network_name
        type             = "ovn-k8s-cni-overlay"
        topology         = "localnet"
        netAttachDefName = "${var.nad_namespace}/${var.network_name}"
        mtu              = 1500
        ipam             = {}
      })
    }
  })
}

# b) macvlan with host-local IPAM: the cluster allocates the address itself from
#    the given subnet over the node's physical interface.
resource "kubectl_manifest" "nad_macvlan" {
  yaml_body = yamlencode({
    apiVersion = "k8s.cni.cncf.io/v1"
    kind       = "NetworkAttachmentDefinition"
    metadata   = { name = "${var.network_name}-subnet", namespace = var.ns }
    spec = {
      config = jsonencode({
        cniVersion = "0.3.1"
        name       = "${var.network_name}-subnet"
        plugins = [{
          type   = "macvlan"
          master = var.host_iface
          mode   = "bridge"
          ipam = {
            type       = "host-local"
            subnet     = "192.0.2.0/24"
            rangeStart = "192.0.2.10"
            rangeEnd   = "192.0.2.250"
          }
        }]
      })
    }
  })
}
