# Proxmox VE HA across VMs: every HA group (vms.<name>.ha.group) with two or more VMs gets a
# negative resource-affinity rule, so HA never places two of them on one node (a node failure
# must not take out two Patroni members, both DNS servers, ...). There is no home node: HA may
# run a VM anywhere else, and the VM resource ignores node_name after creation. The per-VM HA
# resource is in modules/proxmox/vm/ha.tf.
#
# App-level HA (keepalived VIPs, Patroni, Kea HA) moves the *service* within seconds; Proxmox HA
# brings the *dead member* back on another node within minutes (fencing + restart), so the
# service is redundant again without anyone touching it.
locals {
  ha_groups = {
    for g in distinct(compact([for vm in values(local.selected_vms) : try(vm.ha.group, null)])) :
    g => sort([for name, vm in local.selected_vms : name if try(vm.ha.group, null) == g])
  }
}

resource "proxmox_harule" "spread" {
  for_each  = { for g, names in local.ha_groups : g => names if length(names) > 1 }
  rule      = "spread-${each.key}"
  type      = "resource-affinity"
  affinity  = "negative"
  comment   = "Managed by OpenTofu: ${join(", ", each.value)} on separate nodes"
  resources = [for name in each.value : module.vm[name].ha_resource_id]
}

output "ha_groups" {
  description = "HA groups and their VMs (each group's VMs are kept on separate nodes)."
  value       = local.ha_groups
}
