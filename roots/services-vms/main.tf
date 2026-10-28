locals {
  selected_vms = { for name, vm in var.vms : name => vm if vm.owner == "services-vms" }
  dhcp_vms     = { for name, vm in local.selected_vms : name => vm if vm.role == "dhcp" }
}

module "dhcp_macs" {
  source = "../../modules/services/dhcp/macs"
  vms    = local.dhcp_vms
  vnis   = var.vnis
}

module "vm" {
  source             = "../../modules/proxmox/vm"
  for_each           = local.selected_vms
  name               = each.key
  configure_data_ips = each.value.role != "dhcp"
  vm = merge(each.value, each.value.role == "dhcp" ? {
    # The VM module prepends management as net0. DHCP data NICs are generated
    # solely from VNI inventory, rather than manually listed per DHCP VM.
    network_devices = module.dhcp_macs.network_devices[each.key]
  } : {})
  vm_config   = var.vm_config
  ssh_pubkeys = local.ssh_pubkeys
  vm_images   = var.vm_images
}
