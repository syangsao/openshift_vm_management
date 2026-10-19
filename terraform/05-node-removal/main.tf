# Remove a server from the OCP-Virt cluster.
#
#   1. pre-check: fail if any VM on the node is not LiveMigratable
#   2. live-migrate every VMI whose status.nodeName is this node
#   3. cordon + drain
#   4. delete the Machine / BareMetalHost (Machine API removes the Node)
#   5. power off the BMC (decommission the hardware)
#
# All steps are side-effects: Node objects are cluster-owned, so Terraform
# drives `oc` and chains the steps with depends_on. Order is the contract.

terraform {
  required_version = ">= 1.5"
  required_providers {
    kubectl = { source = "alekc/kubectl", version = ">= 2.4.1, < 3.0.0" }
    null    = { source = "hashicorp/null", version = ">= 3.2.0" }
    redfish = { source = "dell/redfish", version = ">= 1.6.0" }
  }
}

provider "kubectl" {
  config_path = var.kubeconfig
}

variable "kubeconfig" {
  type    = string
  default = "~/.kube/config"
}
variable "node" {
  type    = string
  default = "worker-0.example.com"
}

# Optional: the server's BMC, to power it off at the end. Same shape as 01-rhel.
variable "bmc" {
  type = map(object({
    endpoint     = string
    user         = string
    password     = string
    ssl_insecure = bool
  }))
  default = {}
}

# 1. Fail early if a VM on the node cannot live-migrate (it would block the drain).
resource "null_resource" "precheck" {
  triggers = { node = var.node }
  provisioner "local-exec" {
    command     = <<-EOT
      set -e
      node="${var.node}"
      for vm in $(oc get vm -A -o jsonpath='{range .items[*]}{.metadata.namespace} {.metadata.name}{"\n"}{end}'); do
        set -- $vm
        ns=$1; name=$2
        lm=$(oc get vm "$name" -n "$ns" -o jsonpath='{.status.conditions[?(@.type=="LiveMigratable")].status}' 2>/dev/null || true)
        if [ "$lm" != "True" ]; then
          echo "BLOCKING: $ns/$name is not LiveMigratable (status=$lm). Resolve it before removing $node"
          exit 1
        fi
      done
      echo "All VMs on $node are live-migratable"
    EOT
    interpreter = ["/bin/bash", "-c"]
  }
}

# 2. Live-migrate every VMI currently on the node. nodeName is a status field,
#    not a label, so enumerate from VMI status.
resource "null_resource" "migrate_vms" {
  depends_on = [null_resource.precheck]
  triggers   = { node = var.node }
  provisioner "local-exec" {
    command     = <<-EOT
      set -e
      node="${var.node}"
      for vmi in $(oc get vmi -A -o jsonpath='{range .items[*]}{.metadata.namespace} {.metadata.name} {.status.nodeName}{"\n"}{end}'); do
        set -- $vmi
        ns=$1; name=$2; on=$3
        if [ "$on" = "$node" ]; then
          echo "Migrating $ns/$name off $node"
          oc migrate "$name" -n "$ns" --wait
        fi
      done
      echo "No VMs left on $node"
    EOT
    interpreter = ["/bin/bash", "-c"]
  }
}

# 3. Cordon + drain. With evictionStrategy: LiveMigrate (the cluster default) the
#    drain migrates anything still running; --delete-emptydir-data lets the node
#    actually go away.
resource "null_resource" "drain" {
  depends_on = [null_resource.migrate_vms]
  triggers   = { node = var.node }
  provisioner "local-exec" {
    command     = "oc adm cordon ${var.node} && oc adm drain ${var.node} --ignore-daemonsets --delete-emptydir-data"
    interpreter = ["/bin/bash", "-c"]
  }
}

# 4. Tell the Machine API to scale the node down. For user-provisioned metal the
#    node also has a BareMetalHost (BMO); delete both so the Node is removed.
resource "null_resource" "delete_machine" {
  depends_on = [null_resource.drain]
  triggers   = { node = var.node }
  provisioner "local-exec" {
    command     = "oc delete machine ${var.node} --ignore-not-found && oc delete baremetalhost ${var.node} -n openshift-metal --ignore-not-found"
    interpreter = ["/bin/bash", "-c"]
  }
}

# 5. Decommission the hardware: power off the BMC. Skipped entirely when var.bmc
#    is empty.
resource "redfish_power" "off" {
  for_each             = var.bmc
  depends_on           = [null_resource.delete_machine]
  desired_power_action = "ForceOff"
  redfish_server {
    endpoint     = each.value.endpoint
    user         = each.value.user
    password     = each.value.password
    ssl_insecure = each.value.ssl_insecure
  }
}
