mock_provider "oci" {
  mock_data "oci_identity_regions" {
    defaults = { regions = [{ name = "eu-amsterdam-1", key = "AMS" }] }
  }
  mock_data "oci_identity_tenancy" {
    defaults = { home_region_key = "AMS" }
  }
}
mock_provider "oci" { alias = "home" }
variables {
  tenancy_ocid               = "ocid1.tenancy.oc1..test"
  region                     = "eu-amsterdam-1"
  instance_compartment_ocid  = "ocid1.compartment.oc1..servers"
  secret_compartment_ocid    = "ocid1.compartment.oc1..secrets"
  ad_credentials_secret_ocid = "ocid1.vaultsecret.oc1.eu-amsterdam-1.test"
}
run "shared_tag_identity_and_scoped_access" {
  command = plan
  assert {
    condition     = oci_identity_dynamic_group.domain_join.matching_rule == "ALL {instance.compartment.id = 'ocid1.compartment.oc1..servers', tag.ADJoinBootstrap.State.value = 'pending'}"
    error_message = "Membership must be restricted to the selected compartment and bootstrap tag."
  }
  assert {
    condition     = contains(oci_identity_policy.domain_join.statements, "Allow dynamic-group windows-ad-join-bootstrap to {INSTANCE_READ, INSTANCE_UPDATE} in compartment id ocid1.compartment.oc1..servers where request.instance.id = target.instance.id")
    error_message = "Instance updates must be limited to the caller itself."
  }
  assert {
    condition     = contains(oci_identity_policy.domain_join.statements, "Allow dynamic-group windows-ad-join-bootstrap to read secret-bundles in compartment id ocid1.compartment.oc1..secrets where target.secret.id = 'ocid1.vaultsecret.oc1.eu-amsterdam-1.test'")
    error_message = "Secret access must be restricted to the selected secret."
  }
}
run "custom_tag_rule" {
  command = plan
  variables {
    bootstrap_tag_namespace = "CorpADJoin"
    bootstrap_tag_key       = "Enrollment"
    bootstrap_tag_value     = "enabled"
  }
  assert {
    condition     = strcontains(oci_identity_dynamic_group.domain_join.matching_rule, "tag.CorpADJoin.Enrollment.value = 'enabled'")
    error_message = "Custom tag settings must be reflected in shared membership."
  }
}
run "reject_rule_injection" {
  command = plan
  variables { bootstrap_tag_value = "pending'" }
  expect_failures = [var.bootstrap_tag_value]
}
