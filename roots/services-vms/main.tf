locals {
  # Preserve module.vm[<name>] state addresses for both service groups.
  selected_vms = {
    for name, vm in var.vms : name => vm
    if contains(["services-vms", "services-vms-dns", "services-vms-dhcp"], vm.owner)
  }

  # Padded VLAN keys give deterministic numeric ordering for the guest NICs.
  dhcp_l2vnis = {
    for l2 in flatten([
      for l3 in var.vnis : [
        for l2 in values(l3.l2) : l2 if l2.dhcp != null
      ]
    ]) : format("%04d", l2.vlan_id) => l2
  }

  dhcp_network_devices = [
    for l2 in values(local.dhcp_l2vnis) : {
      bridge  = "vmbr4000"
      vlan_id = l2.vlan_id
    }
  ]
}

module "vm" {
  source      = "../../modules/proxmox/vm"
  for_each    = local.selected_vms
  name        = each.key
  configure_data_nic_ips = each.value.owner != "services-vms-dhcp"
  vm = merge(each.value, each.value.owner == "services-vms-dhcp" ? {
    # The VM module prepends management as net0. DHCP data NICs are generated
    # solely from VNI inventory, rather than manually listed per DHCP VM.
    network_devices = local.dhcp_network_devices
  } : {})
  vm_config   = var.vm_config
  ssh_pubkeys = local.ssh_pubkey
  vm_images   = var.vm_images
}
