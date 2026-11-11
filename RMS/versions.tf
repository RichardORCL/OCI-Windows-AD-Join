terraform {
  required_version = ">= 1.2.0, < 2.0.0"
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = ">= 6.0.0, < 9.0.0"
    }
  }
}

provider "oci" {
  region = var.region
}

# IAM resources live in the tenancy home region, even when Compute does not.
data "oci_identity_regions" "all" {}
data "oci_identity_tenancy" "this" {
  tenancy_id = var.tenancy_ocid
}
locals {
  home_region = one([for r in data.oci_identity_regions.all.regions : r.name if r.key == data.oci_identity_tenancy.this.home_region_key])
}
provider "oci" {
  alias  = "home"
  region = local.home_region
}
