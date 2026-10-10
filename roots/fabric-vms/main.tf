module "proxmox_fabric_macs" {
  source = "../../modules/fabric/macs"

  nodes = merge(
    var.nodes.proxmox_cluster,
    local.greatfox_nodes,
  )

  underlay_bridges       = var.fabric_vms.default_underlay_bridges
  underlay_local_as_base = var.fabric_vms.underlay_local_as_base
}

module "vm" {
  source   = "../../modules/proxmox/vm"
  for_each = var.nodes.proxmox_cluster

  name = "${var.fabric_vms.hostname_prefix}${each.key}"

  vm = merge({
    image              = "vyos"
    started            = true
    tags               = ["opentofu", "debian", "vyos", "vxlan"]
    node               = each.key
    vm_id              = each.value.id + var.fabric_vms.vm_id_offset
    management_address = "${cidrhost(var.fabric_vms.management_prefix, each.value.id)}/${var.fabric_vms.management_cidr}"
    network_devices    = module.proxmox_fabric_macs.network_devices[each.key]
    }, [
    for name, vm in var.vms : {
      for key, value in vm : key => value if value != null
    } if name == "${var.fabric_vms.hostname_prefix}${each.key}" && vm.owner == "fabric-vms"
  ]...)

  vm_config = var.vm_config
  vm_images = var.vm_images
}

module "greatfox_vm" {
  source   = "../../modules/proxmox/vm"
  for_each = local.greatfox_nodes

  providers = {
    proxmox = proxmox.greatfox
  }

  name = "${var.fabric_vms.hostname_prefix}${each.key}"

  vm = merge({
    image              = "vyos"
    started            = true
    tags               = ["opentofu", "debian", "vyos", "vxlan"]
    node               = each.key
    vm_id              = each.value.id + var.fabric_vms.vm_id_offset
    management_address = "${cidrhost(var.fabric_vms.management_prefix, each.value.id)}/${var.fabric_vms.management_cidr}"
    network_devices    = module.proxmox_fabric_macs.network_devices[each.key]
    }, [
    for name, vm in var.vms : {
      for key, value in vm : key => value if value != null
    } if name == "${var.fabric_vms.hostname_prefix}${each.key}" && vm.owner == "fabric-vms"
  ]...)

  vm_config = var.vm_config
  vm_images = var.vm_images
}
