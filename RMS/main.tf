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
  image_id = var.image_ocid != "" ? var.image_ocid : try(data.oci_core_images.windows[0].images[0].id, null)
  bootstrap_config = {
    computer_name = upper(var.computer_name)
    domain        = lower(var.ad_domain_name)
    override_dns  = var.override_dns
    dns_servers   = var.override_dns ? [for ip in split(",", var.ad_dns_servers) : trimspace(ip) if trimspace(ip) != ""] : []
    ou_path       = var.ad_ou_path
    secret_id     = var.ad_credentials_secret_ocid
    region        = var.region
  }
  user_data = templatefile("${path.module}/scripts/bootstrap.ps1.tftpl", {
    config_base64 = base64encode(jsonencode(local.bootstrap_config))
    worker_base64 = filebase64("${path.module}/scripts/join-domain.ps1")
    helper_base64 = filebase64("${path.module}/scripts/read_secret.py")
  })
}

resource "oci_core_instance" "windows" {
  compartment_id      = var.compartment_ocid
  availability_domain = var.availability_domain
  display_name        = var.instance_name
  shape               = var.shape
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
    nsg_ids          = var.nsg_ocids
    # Do not publish a VCN DNS hostname which conflicts with AD DNS ownership.
  }
  metadata = { user_data = base64encode(local.user_data) }
  instance_options {
    are_legacy_imds_endpoints_disabled = true
  }
  lifecycle {
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

resource "oci_identity_dynamic_group" "domain_join" {
  count          = var.create_iam_resources ? 1 : 0
  provider       = oci.home
  compartment_id = var.tenancy_ocid
  name           = "win-ad-${substr(sha256(oci_core_instance.windows.id), 0, 16)}"
  description    = "Only the Windows instance created by this stack"
  matching_rule  = "ALL {instance.id = '${oci_core_instance.windows.id}'}"
}

resource "oci_identity_policy" "domain_join" {
  count          = var.create_iam_resources ? 1 : 0
  provider       = oci.home
  compartment_id = var.tenancy_ocid
  name           = "${oci_identity_dynamic_group.domain_join[0].name}-secret"
  description    = "Read only the selected AD join credential secret"
  statements = [
    "Allow dynamic-group ${oci_identity_dynamic_group.domain_join[0].name} to read secret-bundles in compartment id ${var.secret_compartment_ocid} where target.secret.id = '${var.ad_credentials_secret_ocid}'"
  ]
}
