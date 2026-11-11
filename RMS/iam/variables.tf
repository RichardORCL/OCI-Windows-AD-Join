variable "tenancy_ocid" { type = string }
variable "region" {
  type        = string
  description = "Region used for discovery; IAM is managed in the tenancy home region."
}
variable "instance_compartment_ocid" {
  type        = string
  description = "Only tagged servers in this compartment can join the group."
}
variable "secret_compartment_ocid" { type = string }
variable "ad_credentials_secret_ocid" {
  type = string
  validation {
    condition     = can(regex("^ocid1\\.vaultsecret\\.[A-Za-z0-9._-]+$", var.ad_credentials_secret_ocid))
    error_message = "Choose an OCI Vault secret."
  }
}
variable "iam_name" {
  type    = string
  default = "windows-ad-join-bootstrap"
  validation {
    condition     = can(regex("^[A-Za-z][A-Za-z0-9_-]{0,63}$", var.iam_name))
    error_message = "Use a name of 1–64 letters, digits, underscores or hyphens, starting with a letter."
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
