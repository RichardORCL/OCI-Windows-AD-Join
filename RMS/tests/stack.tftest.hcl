# Offline plans: mocks never authenticate to OCI or provision resources.
mock_provider "oci" {
  mock_data "oci_identity_regions" {
    defaults = { regions = [{ name = "eu-amsterdam-1", key = "AMS" }] }
  }
  mock_data "oci_identity_tenancy" {
    defaults = { home_region_key = "AMS" }
  }
  mock_data "oci_core_images" {
    defaults = { images = [{ id = "ocid1.image.oc1.eu-amsterdam-1.test" }] }
  }
}
mock_provider "oci" {
  alias = "home"
}
variables {
  tenancy_ocid               = "ocid1.tenancy.oc1..test"
  compartment_ocid           = "ocid1.compartment.oc1..test"
  region                     = "eu-amsterdam-1"
  availability_domain        = "test:EU-AMSTERDAM-1-AD-1"
  network_compartment_ocid   = "ocid1.compartment.oc1..network"
  vcn_ocid                   = "ocid1.vcn.oc1.eu-amsterdam-1.test"
  subnet_ocid                = "ocid1.subnet.oc1.eu-amsterdam-1.test"
  ad_domain_name             = "corp.example.com"
  ad_dns_servers             = "10.0.0.10, 10.0.0.11"
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
    condition     = length(oci_identity_dynamic_group.domain_join) == 1 && length(oci_identity_policy.domain_join) == 1
    error_message = "Create dedicated IAM resources by default."
  }
}
run "explicit_image_and_existing_iam" {
  command = plan
  variables {
    image_ocid           = "ocid1.image.oc1.eu-amsterdam-1.override"
    create_iam_resources = false
  }
  assert {
    condition     = oci_core_instance.windows.source_details[0].source_id == "ocid1.image.oc1.eu-amsterdam-1.override" && length(data.oci_core_images.windows) == 0
    error_message = "An image override must bypass automatic image lookup."
  }
  assert {
    condition     = length(oci_identity_dynamic_group.domain_join) == 0 && length(oci_identity_policy.domain_join) == 0
    error_message = "Existing IAM mode must not create IAM resources."
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
