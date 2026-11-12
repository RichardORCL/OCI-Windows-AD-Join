variable "compartment_ocid" {
  type        = string
  description = "Compartment for the instance."
}
variable "region" {
  type        = string
  description = "Compute region. Use a secret in this region."
}
variable "availability_domain" {
  type = string
}
variable "instance_name" {
  type    = string
  default = "windows-ad-member"
}
variable "computer_name" {
  type    = string
  default = "OCI-WIN01"
  validation {
    condition     = can(regex("^[A-Za-z0-9]([A-Za-z0-9-]{0,13}[A-Za-z0-9])?$", var.computer_name)) && !can(regex("^[0-9]+$", var.computer_name))
    error_message = "Use a unique Windows name: 1–15 letters, numbers or hyphens, with no leading/trailing hyphen and not all numeric."
  }
}
variable "shape" {
  type    = string
  default = "VM.Standard.E4.Flex"
  validation {
    condition     = can(regex("^VM\\.Standard\\.(E[3-9]|[3-9]|Intel[3-9])\\.Flex$", var.shape))
    error_message = "Choose an x86 Standard Flex VM shape; ARM and bare metal are not supported by this stack."
  }
}
variable "ocpus" {
  type    = number
  default = 2
  validation {
    condition     = var.ocpus >= 1 && var.ocpus <= 64 && floor(var.ocpus) == var.ocpus
    error_message = "OCPUs must be a whole number between 1 and 64; shape-specific limits also apply."
  }
}
variable "memory_in_gbs" {
  type    = number
  default = 16
  validation {
    condition     = var.memory_in_gbs >= 8 && var.memory_in_gbs <= 1024 && floor(var.memory_in_gbs) == var.memory_in_gbs
    error_message = "Memory must be a whole number between 8 and 1024 GiB; shape-specific limits also apply."
  }
}
variable "windows_server_version" {
  type    = string
  default = "2022"
  validation {
    condition     = contains(["2019", "2022", "2025"], var.windows_server_version)
    error_message = "Select Windows Server 2019, 2022 or 2025."
  }
}
variable "image_ocid" {
  type        = string
  default     = ""
  description = "Optional image override; otherwise use the latest compatible Standard Edition VM platform image."
}
variable "boot_volume_size_in_gbs" {
  type    = number
  default = 100
  validation {
    condition     = var.boot_volume_size_in_gbs >= 100 && var.boot_volume_size_in_gbs <= 32768 && floor(var.boot_volume_size_in_gbs) == var.boot_volume_size_in_gbs
    error_message = "Boot volume must be a whole number between 100 and 32768 GiB (and at least the image minimum)."
  }
}
variable "network_compartment_ocid" {
  type = string
}
variable "vcn_ocid" {
  type = string
}
variable "subnet_ocid" {
  type = string
}
variable "nsg_ocids" {
  type        = string
  default     = ""
  description = "Optional comma-separated NSG OCIDs or a JSON array encoded as a string. Blank attaches no NSGs."
}
variable "assign_public_ip" {
  type    = bool
  default = false
}
variable "private_ip" {
  type    = string
  default = ""
  validation {
    condition     = var.private_ip == "" || can(cidrnetmask("${var.private_ip}/32"))
    error_message = "Private IP must be blank or a valid IPv4 address."
  }
}
variable "secret_compartment_ocid" {
  type = string
}
variable "ad_credentials_secret_ocid" {
  type        = string
  description = "OCID only. Secret content is never read by Terraform."
  validation {
    condition     = can(regex("^ocid1\\.vaultsecret\\.[A-Za-z0-9._-]+$", var.ad_credentials_secret_ocid))
    error_message = "Choose an existing OCI Vault secret."
  }
}

variable "bootstrap_tag_namespace" {
  type        = string
  default     = "ADJoinBootstrap"
  description = "Bootstrap defined-tag namespace; must match the reusable IAM stack."
  validation {
    condition     = can(regex("^[A-Za-z][A-Za-z0-9_]{0,63}$", var.bootstrap_tag_namespace))
    error_message = "Use 1–64 letters, digits or underscores, starting with a letter."
  }
}
variable "bootstrap_tag_key" {
  type        = string
  default     = "State"
  description = "Bootstrap defined-tag key; must match the reusable IAM stack."
  validation {
    condition     = can(regex("^[A-Za-z][A-Za-z0-9_]{0,63}$", var.bootstrap_tag_key))
    error_message = "Use 1–64 letters, digits or underscores, starting with a letter."
  }
}
variable "bootstrap_tag_value" {
  type        = string
  default     = "pending"
  description = "Bootstrap defined-tag value; must match the reusable IAM stack."
  validation {
    condition     = can(regex("^[A-Za-z][A-Za-z0-9_]{0,63}$", var.bootstrap_tag_value))
    error_message = "Use 1–64 letters, digits or underscores, starting with a letter."
  }
}
