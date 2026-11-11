output "instance_ocid" {
  value = oci_core_instance.windows.id
}
output "private_ip" {
  value = oci_core_instance.windows.private_ip
}
output "public_ip" {
  value = oci_core_instance.windows.public_ip
}
output "image_ocid" {
  value = local.image_id
}
output "domain_join_status_location" {
  value = "C:\\ProgramData\\OCI-ADJoin\\status.json (inside the guest; Apply success does not mean domain join success)"
}
