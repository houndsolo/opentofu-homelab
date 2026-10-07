resource "proxmox_virtual_environment_file" "dns_user_data" {
  for_each     = var.network_services.dns
  node_name    = var.network_services.dns_bootstrap.node
  datastore_id = var.network_services.dns_bootstrap.datastore_id
  content_type = "snippets"
  source_raw {
    file_name = "network-services-${each.key}.yaml"
    data = "#cloud-config\n${yamlencode({
      hostname         = each.key
      manage_etc_hosts = true
      ssh_pwauth       = false
      package_update   = true
      packages         = ["qemu-guest-agent"]
      users = [{
        name                = var.network_services.dns_bootstrap.username
        shell               = "/bin/bash"
        lock_passwd         = true
        sudo                = "ALL=(ALL) NOPASSWD:ALL"
        ssh_authorized_keys = var.dns_ssh_public_keys
      }]
      runcmd = ["systemctl enable --now qemu-guest-agent"]
    })}"
  }
}
