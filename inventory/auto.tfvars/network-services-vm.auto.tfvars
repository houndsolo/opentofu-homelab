network_services_vm = {
  cpu_cores               = 2
  memory_mb               = 2048
  disk_size_gb            = 10
  datastore_id            = "ceph_rbd"
  cloud_init_datastore_id = "ceph_rbd"
  management_bridge       = "vmbr0"
  started                 = true
}
