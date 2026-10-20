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
  #url          = "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2"
  url          = "https://cloud.debian.org/images/cloud/trixie/20261017-2634/debian-13-genericcloud-amd64-20261017-2634.qcow2"

  overwrite    = false
}

locals {
  debian_nodes = sort(distinct([
    for vm in values(local.selected_vms) : vm.node if vm.image == "debian13"
  ]))
}

#resource "proxmox_virtual_environment_file" "debian_cloud_init" {
#  count = length(local.debian_nodes) > 0 ? 1 : 0
#
#  node_name    = local.debian_nodes[0]
#  datastore_id = "cephfs"
#  content_type = "snippets"
#
#  source_raw {
#    data      = file("${path.module}/cloud-init/debian.yaml")
#    file_name = "debian-guest-agent.yaml"
#  }
#}

module "vm" {
  source              = "../../modules/proxmox/vm"
  for_each            = local.selected_vms
  name                = each.key
  vm                  = each.value
  vm_config           = var.vm_config
  ssh_pubkeys         = local.ssh_pubkey
  vm_images           = var.vm_images
  #vendor_data_file_id = each.value.image == "debian13" ? proxmox_virtual_environment_file.debian_cloud_init[0].id : null

  depends_on = [proxmox_virtual_environment_download_file.debian13]
}
