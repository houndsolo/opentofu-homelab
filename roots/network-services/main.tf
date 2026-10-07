module "images" {
  source = "../../modules/proxmox/download-images"
  images = { debian_13 = var.debian_image }
}

module "dhcp" {
  source   = "../../modules/proxmox/vm"
  for_each = var.network_services.dhcp
  name     = each.key
  vm = {
    node               = each.value.node
    vm_id              = each.value.vm_id
    management_address = each.value.management_address
  }
  vm_config = merge(var.network_services_vm, {
    import_image      = var.pve_leaf.vm_config.import_image
    user_data_file_id = var.network_services.dhcp_user_data_file_id
    tags              = ["opentofu", "vyos", "dhcp"]
  })
}

module "dns" {
  source   = "../../modules/proxmox/vm"
  for_each = var.network_services.dns
  name     = each.key
  vm = {
    node               = each.value.node
    vm_id              = each.value.vm_id
    management_address = each.value.management_address
    network_devices = [{
      bridge  = var.network_services.dns_network.bridge
      vlan_id = var.network_services.dns_network.vlan_id
    }]
    ip_configs = [
      { address = each.value.management_address },
      { address = each.value.service_address, gateway = var.network_services.dns_network.gateway },
    ]
  }
  vm_config = merge(var.network_services_vm, {
    import_image      = module.images.file_ids.debian_13
    user_data_file_id = proxmox_virtual_environment_file.dns_user_data[each.key].id
    vga_type          = "serial0"
    underlay_mtu      = 0
    tags              = ["opentofu", "debian", "dns"]
  })
}
