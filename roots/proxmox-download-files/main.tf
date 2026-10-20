locals {
  # cephfs is shared, so download once through a node hosting a Debian VM.
  debian_nodes = sort(distinct([
    for vm in values(var.vms) : vm.node
    if vm.image == "debian13" && vm.node != null
  ]))
}

resource "proxmox_virtual_environment_download_file" "debian13" {
  count = length(local.debian_nodes) > 0 ? 1 : 0

  node_name    = local.debian_nodes[0]
  datastore_id = "cephfs"
  content_type = "import"
  file_name    = "debian-13-genericcloud-amd64.qcow2"
  url          = "https://cloud.debian.org/images/cloud/trixie/20261017-2634/debian-13-genericcloud-amd64-20261017-2634.qcow2"
  overwrite    = false
}
