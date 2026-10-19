# Open a Red Hat support case via the Customer Portal / Case Management API.
#
# This is NOT infrastructure state - it is an external ticket - so it is a
# side-effect: null_resource + local-exec firing a POST. The call is keyed on
# subject+description, so re-apply with unchanged values does not reopen it.
#
# CONFIRM the base URL, required fields, and product IDs against the current
# Customer Portal Integration Guide - the values here are placeholders.

terraform {
  required_version = ">= 1.5"
  required_providers {
    null = { source = "hashicorp/null", version = ">= 3.2.0" }
  }
}

# Red Hat Customer Portal API bearer token (RH SSO / Customer Portal API access).
variable "rh_token" {
  type      = string
  sensitive = true
  default   = ""
}

variable "case_base_url" {
  type        = string
  description = "Confirm against the current Customer Portal Integration Guide"
  default     = "https://api.access.redhat.com/support/cases"
}

variable "subject" {
  type    = string
  default = "OpenShift Virtualization issue"
}
variable "description" {
  type    = string
  default = "Describe the problem, cluster version (OCP 4.22 / CNV v1), and steps to reproduce."
}
variable "product_id" {
  type        = number
  description = "Portal product ID for the affected product - account/product-specific, confirm it"
  default     = 187
}

resource "null_resource" "rh_case" {
  triggers = {
    subject     = var.subject
    description = var.description
  }
  provisioner "local-exec" {
    command     = <<-EOT
      set -e
      [ -n "${var.rh_token}" ] || { echo "rh_token is required to open a case"; exit 1; }
      curl -sS -f -X POST \
        -H "Authorization: Bearer ${var.rh_token}" \
        -H "Content-Type: application/json" \
        "${var.case_base_url}" \
        -d '{"subject":"${var.subject}","description":"${var.description}","product_id":${var.product_id}}'
      echo
    EOT
    interpreter = ["/bin/bash", "-c"]
  }
}
