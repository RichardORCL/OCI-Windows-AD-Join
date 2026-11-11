output "dynamic_group_ocid" { value = oci_identity_dynamic_group.domain_join.id }
output "matching_rule" { value = oci_identity_dynamic_group.domain_join.matching_rule }
output "server_stack_settings" {
  description = "Copy these nonsecret settings into each server stack."
  value = {
    compartment_ocid           = var.instance_compartment_ocid
    ad_credentials_secret_ocid = var.ad_credentials_secret_ocid
    secret_compartment_ocid    = var.secret_compartment_ocid
    bootstrap_tag_namespace    = var.bootstrap_tag_namespace
    bootstrap_tag_key          = var.bootstrap_tag_key
    bootstrap_tag_value        = var.bootstrap_tag_value
  }
}
