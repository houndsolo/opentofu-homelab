locals {
  selected_vms = {
    for name, vm in var.vms : name => vm
    if vm.owner == "services-vms"
  }
}

resource "proxmox_virtual_environment_download_file" "debian13" {
  # cephfs is shared, so download once through a node hosting a Debian VM.
  count = length(local.debian_nodes) > 0 ? 1 : 0

  node_name    = local.debian_nodes[0]
  datastore_id = "cephfs"
  content_type = "import"
  file_name    = "debian-13-genericcloud-amd64.qcow2"
  url          = "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2"
  overwrite    = false
}

locals {
  debian_nodes = sort(distinct([
    for vm in values(local.selected_vms) : vm.node if vm.image == "debian13"
  ]))
}

module "vm" {
  source    = "../../modules/proxmox/vm"
  for_each  = local.selected_vms
  name      = each.key
  vm        = each.value
  vm_config = var.vm_config
  vm_images = var.vm_images

  depends_on = [proxmox_virtual_environment_download_file.debian13]
}
