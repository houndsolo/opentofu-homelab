vm_config = {
  datastore_id = "ceph_rbd"
  import_image = "cephfs:import/debian-13-genericcloud-amd64.qcow2"
}

# These files must already exist in Proxmox storage.
vm_images = {
  debian13 = {
    import_image = "cephfs:import/debian-13-genericcloud-amd64.qcow2"
    tags         = ["opentofu", "debian"]
  }
  vyos = {
    import_image      = "cephfs:import/vyos-1.5-rolling-202608270227-generic-amd64.qcow2"
    user_data_file_id = "cephfs:snippets/vyos_api.yml"
    tags              = ["opentofu", "vyos"]
  }
}
