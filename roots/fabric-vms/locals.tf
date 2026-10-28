locals {
  # A vms entry named <hostname_prefix><node> with owner = "fabric-vms"
  # overrides fields of that node's generated VM.
  overrides = {
    for name, vm in var.vms : trimprefix(name, var.fabric_vms.hostname_prefix) => vm
    if vm.owner == "fabric-vms"
  }

  fabric_vms = {
    for name, node in var.nodes.proxmox : name => merge(
      {
        image              = "vyos"
        node               = name
        vm_id              = node.id + var.fabric_vms.vm_id_offset
        management_address = "${cidrhost(var.fabric.settings.management_prefix, node.id)}/${var.fabric.settings.management_prefix_length}"
        network_devices    = module.proxmox_fabric_macs.network_devices[name]
      },
      {
        for key, value in try(local.overrides[name], {}) : key => value
        if value != null && key != "config"
      },
      {
        config = merge(
          { started = true, tags = ["opentofu", "debian", "vyos", "vxlan"] },
          { for key, value in try(local.overrides[name].config, {}) : key => value if value != null },
        )
      },
    )
  }
}
