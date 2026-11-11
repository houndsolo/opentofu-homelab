# Proxmox VE HA for this VM (var.vm.ha). The anti-affinity rule that keeps a group's VMs on
# separate nodes spans VMs, so it lives in the calling root (roots/services-vms/ha.tf).

resource "proxmox_haresource" "this" {
  count        = var.vm.ha == null ? 0 : 1
  resource_id  = "vm:${proxmox_virtual_environment_vm.this.vm_id}"
  state        = var.vm.ha.state
  failback     = var.vm.ha.failback
  max_restart  = var.vm.ha.max_restart
  max_relocate = var.vm.ha.max_relocate
  comment      = "Managed by OpenTofu: ${var.name}, HA group ${var.vm.ha.group}"
}

# Soft home node: HA may run the VM on any node, but prefers (and with failback returns it to)
# the inventory node, so placement and the plan stay where the inventory says.
resource "proxmox_harule" "home" {
  count     = var.vm.ha == null ? 0 : 1
  rule      = "home-${var.name}"
  type      = "node-affinity"
  comment   = "Managed by OpenTofu: ${var.name} prefers ${var.vm.node}"
  resources = [proxmox_haresource.this[0].resource_id]
  nodes     = { (var.vm.node) = 2 }
  strict    = false
}
