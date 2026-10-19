# Provision a bare-metal server to Redfish -> PXE -> RHEL 9, then wait for the OS.
#
# Terraform does NOT install RHEL. It drives the BMC (boot to PXE, power on) and
# polls until a reachable RHEL 9 answers. The actual install is done by your
# PXE/kickstart stack, which is external to Terraform.

terraform {
  required_version = ">= 1.5"
  required_providers {
    redfish = { source = "dell/redfish", version = ">= 1.6.0" }
    null    = { source = "hashicorp/null", version = ">= 3.2.0" }
  }
}

# One entry per server to provision.
variable "servers" {
  type = map(object({
    endpoint     = string # BMC/iDRAC address, e.g. "https://192.0.2.11"
    user         = string # BMC user
    password     = string # BMC password
    ssl_insecure = bool   # true for self-signed iDRAC certs
    os_ip        = string # where the OS will be reachable (for the wait step)
  }))
  default = {
    # "node-01" = {
    #   endpoint = "https://192.0.2.11", user = "admin", password = "changeme",
    #   ssl_insecure = true, os_ip = "192.0.2.21"
    # }
  }
}

# 1. Point the next boot at the network (PXE) so the kickstack can load, and
#    reset so it takes effect.
resource "redfish_boot_source_override" "pxe" {
  for_each                    = var.servers
  boot_source_override_target = "Pxe"
  boot_source_override_mode   = "UEFI"
  reset_type                  = "ForceRestart"
  redfish_server {
    endpoint     = each.value.endpoint
    user         = each.value.user
    password     = each.value.password
    ssl_insecure = each.value.ssl_insecure
  }
}

# 2. Power the server on. It PXE-boots and the kickstack installs RHEL 9.
resource "redfish_power" "on" {
  for_each             = var.servers
  desired_power_action = "ForceOn"
  depends_on           = [redfish_boot_source_override.pxe]
  redfish_server {
    endpoint     = each.value.endpoint
    user         = each.value.user
    password     = each.value.password
    ssl_insecure = each.value.ssl_insecure
  }
}

# 3. Wait until the OS is actually up (RHEL 9 reached, ssh answers).
#    The install is done by the external PXE/kickstart stack; this just gates on it.
resource "null_resource" "wait_rhel" {
  for_each   = var.servers
  depends_on = [redfish_power.on]
  triggers   = { ip = each.value.os_ip }
  provisioner "local-exec" {
    command     = "for i in $(seq 1 120); do ssh -o Batch=yes -o ConnectTimeout=5 root@${each.value.os_ip} 'test -f /etc/redhat-release && grep -q 9 /etc/redhat-release' && exit 0; sleep 30; done; echo 'RHEL 9 never became reachable on ${each.value.os_ip}'"
    interpreter = ["/bin/bash", "-c"]
  }
}
