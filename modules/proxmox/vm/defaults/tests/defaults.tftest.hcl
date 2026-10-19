variables {
  name = "test"
  vm   = { node = "venom", vm_id = 999 }
  vm_config = {
    datastore_id = "ceph_rbd"
    import_image = "cephfs:import/debian-13-genericcloud-amd64.qcow2"
  }
  vm_images = {
    debian13 = { import_image = "cephfs:import/debian-13-genericcloud-amd64.qcow2", tags = ["opentofu", "debian"] }
    vyos     = { import_image = "cephfs:import/vyos.qcow2", user_data_file_id = "cephfs:snippets/vyos_api.yml", tags = ["opentofu", "vyos"] }
  }
}
run "dns_defaults" {
  command = plan
  variables { vm = { node = "venom", vm_id = 301, image = "debian13", cores = 2, memory_mb = 2048 } }
  assert {
    condition     = output.config.datastore_id == "ceph_rbd" && output.config.import_image == "cephfs:import/debian-13-genericcloud-amd64.qcow2" && output.config.user_data_file_id == null && output.config.cpu_cores == 2 && output.config.memory_mb == 2048
    error_message = "DNS must use Debian and shared storage, without the VyOS snippet."
  }
}
run "dhcp_image_and_overrides" {
  command = plan
  variables { vm = { node = "venom", vm_id = 302, image = "vyos", started = true, config = { started = false, disk_size_gb = 20, tags = [], cpu_limit = 0, cloud_init = false } } }
  assert {
    condition     = output.config.import_image == "cephfs:import/vyos.qcow2" && output.config.user_data_file_id == "cephfs:snippets/vyos_api.yml" && !output.config.started && output.config.disk_size_gb == 20 && length(output.config.tags) == 0 && output.config.cpu_limit == 0 && !output.config.cloud_init && output.config.cpu_cores == 4
    error_message = "VyOS selection and explicit false, zero and empty list overrides must survive the merge."
  }
}
run "debian_clears_shared_vyos_snippet" {
  command = plan
  variables {
    vm        = { node = "venom", vm_id = 301, image = "debian13" }
    vm_config = { datastore_id = "ceph_rbd", import_image = "cephfs:import/vyos.qcow2", user_data_file_id = "cephfs:snippets/vyos_api.yml" }
  }
  assert {
    condition     = output.config.user_data_file_id == null
    error_message = "A Debian image must not inherit a VyOS cloud-init snippet."
  }
}
