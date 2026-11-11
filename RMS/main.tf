data "oci_core_images" "windows" {
  count            = var.image_ocid == "" ? 1 : 0
  compartment_id   = var.compartment_ocid
  operating_system = "Windows"
  shape            = var.shape
  state            = "AVAILABLE"
  sort_by          = "TIMECREATED"
  sort_order       = "DESC"
  filter {
    name   = "display_name"
    values = ["^Windows-Server-${var.windows_server_version}-Standard-Edition-VM-.*"]
    regex  = true
  }
}

locals {
  # Resource Manager can submit an unfilled optional field as an empty string.
  # Accept it as a string first, then normalize to the provider's list of IDs.
  nsg_ids = trimspace(var.nsg_ocids) == "" ? [] : distinct([
    for id in try(tolist(jsondecode(var.nsg_ocids)), split(",", var.nsg_ocids)) : try(trimspace(id), "")
  ])
  image_id = var.image_ocid != "" ? var.image_ocid : try(data.oci_core_images.windows[0].images[0].id, null)
  bootstrap_config = {
    computer_name = upper(var.computer_name)
    domain        = lower(var.ad_domain_name)
    override_dns  = var.override_dns
    dns_servers   = var.override_dns ? [for ip in split(",", var.ad_dns_servers) : trimspace(ip) if trimspace(ip) != ""] : []
    ou_path       = var.ad_ou_path
    secret_id     = var.ad_credentials_secret_ocid
    region        = var.region
    tag_namespace = var.bootstrap_tag_namespace
    tag_key       = var.bootstrap_tag_key
    tag_value     = var.bootstrap_tag_value
  }
  user_data = templatefile("${path.module}/scripts/bootstrap.ps1.tftpl", {
    config_base64  = base64encode(jsonencode(local.bootstrap_config))
    worker_base64  = filebase64("${path.module}/scripts/join-domain.ps1")
    helper_base64  = filebase64("${path.module}/scripts/read_secret.py")
    cleanup_base64 = filebase64("${path.module}/scripts/cleanup_access.py")
  })
}

resource "oci_core_instance" "windows" {
  compartment_id      = var.compartment_ocid
  availability_domain = var.availability_domain
  display_name        = var.instance_name
  shape               = var.shape
  defined_tags        = { "${var.bootstrap_tag_namespace}.${var.bootstrap_tag_key}" = var.bootstrap_tag_value }
  shape_config {
    ocpus         = var.ocpus
    memory_in_gbs = var.memory_in_gbs
  }
  source_details {
    source_type             = "image"
    source_id               = local.image_id
    boot_volume_size_in_gbs = var.boot_volume_size_in_gbs
  }
  create_vnic_details {
    subnet_id        = var.subnet_ocid
    assign_public_ip = var.assign_public_ip
    private_ip       = var.private_ip == "" ? null : var.private_ip
    nsg_ids          = local.nsg_ids
    # Do not publish a VCN DNS hostname which conflicts with AD DNS ownership.
  }
  metadata = { user_data = base64encode(local.user_data) }
  instance_options {
    are_legacy_imds_endpoints_disabled = true
  }
  lifecycle {
    # The guest removes the bootstrap tag. Never reapply it during later plans.
    ignore_changes = [defined_tags]

    precondition {
      condition     = length(local.nsg_ids) <= 5 && alltrue([for id in local.nsg_ids : can(regex("^ocid1\\.networksecuritygroup\\.[A-Za-z0-9._-]+$", id))])
      error_message = "NSGs must be blank or contain up to five valid network security group OCIDs, separated by commas or supplied as a JSON array string."
    }
    precondition {
      condition     = !var.override_dns || trimspace(var.ad_dns_servers) != ""
      error_message = "Enter at least one DNS server IPv4 address when Override DNS servers before AD join is enabled."
    }
    precondition {
      condition     = local.image_id != null
      error_message = "No compatible Windows Standard Edition VM platform image found for this version/shape/region. Choose another combination or supply an image override."
    }
    precondition {
      condition     = length(local.user_data) <= 32000
      error_message = "Bootstrap exceeds the OCI user-data size limit; reduce embedded scripts."
    }
  }
}
