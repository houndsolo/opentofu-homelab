# Replace these example values with your datastore and existing cloud image.
# The VM module defines the available vm_config settings and their defaults.
vm_config = {
  datastore_id = "local-lvm"
  import_image = "local:import/debian-13-genericcloud-amd64.qcow2"
  tags         = ["opentofu", "services"]
}
