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
  # Base build of the file on cephfs. The live file is this build customized in place on 2026-10-19
  # (1259536384 bytes, sha512 b96e0d83...; the stock download, sha512 ec584cca..., is kept beside it as
  # debian-13-genericcloud-amd64.qcow2.bak), so no upstream URL or checksum matches it: it was adopted
  # with `tofu import` and no checksum is set.
  url       = "https://cloud.debian.org/images/cloud/trixie/20261017-2634/debian-13-genericcloud-amd64-20261017-2634.qcow2"
  overwrite = false

  lifecycle {
    # url and node_name force replacement (delete + re-download) in the provider. url is null in imported
    # state, and node_name is just the first node with a Debian VM, which changes when VMs move; neither
    # says anything about the shared file every debian13 VM imports from.
    ignore_changes = [url, node_name]
  }
}

import {
  to = proxmox_virtual_environment_download_file.debian13[0]
  id = "eldarad/cephfs:import/debian-13-genericcloud-amd64.qcow2"
}
