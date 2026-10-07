resource "proxmox_download_file" "this" {
  for_each = var.images

  content_type        = "import"
  node_name           = each.value.node
  datastore_id        = each.value.datastore_id
  url                 = each.value.url
  file_name           = each.value.file_name
  checksum            = each.value.checksum
  checksum_algorithm  = "sha512"
  verify              = true
  overwrite           = false
  overwrite_unmanaged = false
}

output "file_ids" {
  description = "Proxmox import file IDs keyed by image name."
  value       = { for name, image in proxmox_download_file.this : name => image.id }
}
