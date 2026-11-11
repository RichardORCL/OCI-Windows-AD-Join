resource "oci_identity_tag_namespace" "bootstrap" {
  provider       = oci.home
  compartment_id = var.tenancy_ocid
  name           = var.bootstrap_tag_namespace
  description    = "Temporary authorization for Windows Active Directory enrollment"
}
resource "oci_identity_tag" "bootstrap" {
  provider         = oci.home
  tag_namespace_id = oci_identity_tag_namespace.bootstrap.id
  name             = var.bootstrap_tag_key
  description      = "Remove after domain join and secure channel verification"
  validator {
    validator_type = "ENUM"
    values         = [var.bootstrap_tag_value]
  }
}
resource "oci_identity_dynamic_group" "domain_join" {
  provider       = oci.home
  compartment_id = var.tenancy_ocid
  name           = var.iam_name
  description    = "Reusable group for tagged Windows servers during AD enrollment"
  matching_rule  = "ALL {instance.compartment.id = '${var.instance_compartment_ocid}', tag.${var.bootstrap_tag_namespace}.${var.bootstrap_tag_key}.value = '${var.bootstrap_tag_value}'}"
  depends_on     = [oci_identity_tag.bootstrap]
}
resource "oci_identity_policy" "domain_join" {
  provider       = oci.home
  compartment_id = var.tenancy_ocid
  name           = "${var.iam_name}-access"
  description    = "Temporary secret access and permission to remove the caller's bootstrap tag"
  statements = [
    "Allow dynamic-group ${oci_identity_dynamic_group.domain_join.name} to read secret-bundles in compartment id ${var.secret_compartment_ocid} where target.secret.id = '${var.ad_credentials_secret_ocid}'",
    "Allow dynamic-group ${oci_identity_dynamic_group.domain_join.name} to {INSTANCE_READ, INSTANCE_UPDATE} in compartment id ${var.instance_compartment_ocid} where request.instance.id = target.instance.id",
    "Allow dynamic-group ${oci_identity_dynamic_group.domain_join.name} to use tag-namespaces in tenancy where target.tag-namespace.name = '${var.bootstrap_tag_namespace}'"
  ]
}
