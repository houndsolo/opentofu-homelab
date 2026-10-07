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
    network_devices = [
      for vni in sort(keys(local.dhcp_segments)) : {
        bridge      = var.network_services.dhcp_bridge
        vlan_id     = local.dhcp_segments[vni].vlan_id
        mac_address = format("02:70:00:%02x:%02x:%02x", each.value.mac_slot, floor(local.dhcp_segments[vni].vlan_id / 256), local.dhcp_segments[vni].vlan_id % 256)
      }
    ]
  }
  vm_config = merge(var.pve_leaf.vm_config, {
    for key, value in var.network_services.dhcp_vm_config : key => value if value != null
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
  vm_config = merge(var.network_services.dns_vm_config, {
    import_image      = module.images.file_ids.debian_13
    user_data_file_id = proxmox_virtual_environment_file.dns_user_data[each.key].id
    vga_type          = "serial0"
    underlay_mtu      = 0
  })
}
