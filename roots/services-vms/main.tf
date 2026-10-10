locals {
  selected_vms = {
    for name, vm in var.vms : name => vm
    if vm.owner == "services-vms"
  }
}

module "vm" {
  source    = "../../modules/proxmox/vm"
  for_each  = local.selected_vms
  name      = each.key
  vm        = each.value
  vm_config = var.vm_config
  vm_images = var.vm_images
}
