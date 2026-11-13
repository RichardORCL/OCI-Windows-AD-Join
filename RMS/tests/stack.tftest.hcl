# Offline plans: mocks never authenticate to OCI or provision resources.
mock_provider "oci" {
  mock_data "oci_core_images" {
    defaults = { images = [{ id = "ocid1.image.oc1.eu-amsterdam-1.test" }] }
  }
}
variables {
  compartment_ocid           = "ocid1.compartment.oc1..test"
  region                     = "eu-amsterdam-1"
  availability_domain        = "test:EU-AMSTERDAM-1-AD-1"
  network_compartment_ocid   = "ocid1.compartment.oc1..network"
  vcn_ocid                   = "ocid1.vcn.oc1.eu-amsterdam-1.test"
  subnet_ocid                = "ocid1.subnet.oc1.eu-amsterdam-1.test"
  secret_compartment_ocid    = "ocid1.compartment.oc1..secrets"
  ad_credentials_secret_ocid = "ocid1.vaultsecret.oc1.eu-amsterdam-1.test"
}
run "default_private_instance" {
  command = plan
  assert {
    condition     = tobool(oci_core_instance.windows.create_vnic_details[0].assign_public_ip) == false
    error_message = "Instance must be private by default."
  }
  assert {
    condition     = startswith(base64decode(oci_core_instance.windows.metadata.user_data), "#ps1_sysnative")
    error_message = "Windows user data must use the Cloudbase-Init PowerShell header."
  }
  assert {
    condition     = oci_core_instance.windows.defined_tags["ADJoinBootstrap.State"] == "pending"
    error_message = "Each new server must carry the shared bootstrap tag at launch."
  }
}
run "explicit_image_override" {
  command = plan
  variables {
    image_ocid = "ocid1.image.oc1.eu-amsterdam-1.override"
  }
  assert {
    condition     = oci_core_instance.windows.source_details[0].source_id == "ocid1.image.oc1.eu-amsterdam-1.override" && length(data.oci_core_images.windows) == 0
    error_message = "An image override must bypass automatic image lookup."
  }

}
run "no_compatible_image" {
  command = plan
  override_data {
    target = data.oci_core_images.windows[0]
    values = { images = [] }
  }
  expect_failures = [oci_core_instance.windows]
}
run "reject_arm_shape" {
  command = plan
  variables {
    shape = "VM.Standard.A1.Flex"
  }
  expect_failures = [var.shape]
}
run "reject_bad_computer_name" {
  command = plan
  variables {
    computer_name = "123456"
  }
  expect_failures = [var.computer_name]
}

run "domain_configuration_only_in_vault" {
  command = plan
  assert {
    condition     = local.bootstrap_config.config_from_vault && !contains(keys(local.bootstrap_config), "domain") && !contains(keys(local.bootstrap_config), "dns_servers") && !contains(keys(local.bootstrap_config), "ou_path")
    error_message = "Domain settings must be retrieved by the guest from Vault, never supplied through Terraform metadata."
  }
}

run "blank_nsg_input" {
  command = plan
  variables {
    nsg_ocids = ""
  }
  assert {
    condition     = length(oci_core_instance.windows.create_vnic_details[0].nsg_ids) == 0
    error_message = "An empty Resource Manager NSG value must attach no NSGs."
  }
}
run "comma_separated_nsgs" {
  command = plan
  variables {
    nsg_ocids = "ocid1.networksecuritygroup.oc1.eu-amsterdam-1.first, ocid1.networksecuritygroup.oc1.eu-amsterdam-1.second"
  }
  assert {
    condition     = length(oci_core_instance.windows.create_vnic_details[0].nsg_ids) == 2 && contains(oci_core_instance.windows.create_vnic_details[0].nsg_ids, "ocid1.networksecuritygroup.oc1.eu-amsterdam-1.second")
    error_message = "Comma-separated NSGs must be trimmed and attached."
  }
}
run "json_nsg_input" {
  command = plan
  variables {
    nsg_ocids = "[\"ocid1.networksecuritygroup.oc1.eu-amsterdam-1.first\"]"
  }
  assert {
    condition     = length(oci_core_instance.windows.create_vnic_details[0].nsg_ids) == 1
    error_message = "A JSON array string must be supported for Resource Manager/API input."
  }
}
run "reject_invalid_nsg" {
  command = plan
  variables {
    nsg_ocids = "not-an-ocid"
  }
  expect_failures = [oci_core_instance.windows]
}
run "reject_too_many_nsgs" {
  command = plan
  variables {
    nsg_ocids = "ocid1.networksecuritygroup.oc1..a,ocid1.networksecuritygroup.oc1..b,ocid1.networksecuritygroup.oc1..c,ocid1.networksecuritygroup.oc1..d,ocid1.networksecuritygroup.oc1..e,ocid1.networksecuritygroup.oc1..f"
  }
  expect_failures = [oci_core_instance.windows]
}

run "custom_bootstrap_tag" {
  command = plan
  variables {
    bootstrap_tag_namespace = "CorpADJoin"
    bootstrap_tag_key       = "Enrollment"
    bootstrap_tag_value     = "enabled"
  }
  assert {
    condition     = oci_core_instance.windows.defined_tags["CorpADJoin.Enrollment"] == "enabled" && local.bootstrap_config.tag_namespace == "CorpADJoin" && local.bootstrap_config.tag_key == "Enrollment"
    error_message = "The launch tag and guest cleanup configuration must agree."
  }
}

run "optional_windows_features" {
  command = plan
  variables {
    install_rds_session_host  = true
    install_remote_assistance = true
  }
  assert {
    condition     = local.bootstrap_config.install_rds_session_host && local.bootstrap_config.install_remote_assistance
    error_message = "Feature choices must reach the guest configuration."
  }
}
run "windows_features_disabled_by_default" {
  command = plan
  assert {
    condition     = !local.bootstrap_config.install_rds_session_host && !local.bootstrap_config.install_remote_assistance
    error_message = "Optional features must be disabled by default."
  }
}
