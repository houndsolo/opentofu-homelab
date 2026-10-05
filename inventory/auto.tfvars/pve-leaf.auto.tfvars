proxmox_vtep_vm = {
  datastore_id             = "ceph_rbd"
  import_image             = "cephfs:import/vyos-1.5-rolling-202608270227-generic-amd64.qcow2"
  cloud_init_datastore_id  = "ceph_rbd"
  user_data_file_id        = "cephfs:snippets/vyos_api.yml"
  management_bridge        = "vmbr0"
  default_underlay_bridges = ["vmbr4001", "vmbr4002", "vmbr4000"]
  cpu_cores                = 4
  cpu_type                 = "x86-64-v2-AES"
  memory_mb                = 4096
  disk_size_gb             = 10
}
