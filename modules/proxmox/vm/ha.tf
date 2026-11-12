# Proxmox VE HA for this VM (var.vm.ha). HA restarts it on any node; the only placement rule is
# the anti-affinity rule that keeps a group's VMs on separate nodes (only when ha.group is set),
# which spans VMs and so lives in the calling root (roots/services-vms/ha.tf).

resource "proxmox_haresource" "this" {
  count        = var.vm.ha == null ? 0 : 1
  resource_id  = "vm:${proxmox_virtual_environment_vm.this.vm_id}"
  state        = var.vm.ha.state
  max_restart  = var.vm.ha.max_restart
  max_relocate = var.vm.ha.max_relocate
  comment      = var.vm.ha.group == null ? "Managed by OpenTofu: ${var.name}" : "Managed by OpenTofu: ${var.name}, HA group ${var.vm.ha.group}"
}
