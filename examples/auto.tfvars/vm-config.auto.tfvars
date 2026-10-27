# Shared VM defaults. Per-VM config overrides these values.
vm_config = {
  datastore_id      = "ceph_rbd" # Destination disk storage; must exist in PVE.
  import_image      = "cephfs:import/debian-13-genericcloud-amd64.qcow2"
  started           = true
  management_bridge = "vmbr0"
  cpu_cores         = 2
  memory_mb         = 2048
  disk_size_gb      = 10
}

# Existing PVE files, selected by each VM's image field.
# Download/customize images first. DNS guests need Podman/Quadlet and guest agent.
vm_images = {
  debian13 = {
    import_image = "cephfs:import/debian-13-genericcloud-amd64.qcow2"
    tags         = ["opentofu", "debian"]
  }
  vyos = {
    import_image      = "cephfs:import/vyos-1.5-rolling-202608270227-generic-amd64.qcow2"
    user_data_file_id = "cephfs:snippets/vyos_api.yml" # Your existing API bootstrap snippet.
    tags              = ["opentofu", "vyos"]
  }
}
