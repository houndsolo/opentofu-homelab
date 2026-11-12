# Proxmox VE HA across VMs: every HA group (vms.<name>.ha.group) with 2..<cluster node count> VMs gets a
# negative resource-affinity rule, so HA never places two of them on one node (a node failure
# must not take out two Patroni members, both DNS servers, ...). A VM with `ha = {}` (no group) is
# an HA resource without any rule. There is no home node: HA may
# run a VM anywhere else, and the VM resource ignores node_name after creation. The per-VM HA
# resource is in modules/proxmox/vm/ha.tf.
#
# App-level HA (keepalived VIPs, Patroni, Kea HA) moves the *service* within seconds; Proxmox HA
# brings the *dead member* back on another node within minutes (fencing + restart), so the
# service is redundant again without anyone touching it.
locals {
  # PVE drops a negative resource-affinity rule with more resources than cluster nodes (feasibility
  # check in PVE::HA::Rules::ResourceAffinity), so such a group gets no rule here either; the check
  # below warns about it.
  ha_cluster_node_count = length([for node in values(var.nodes.proxmox) : node if !node.standalone])
  ha_groups = {
    for g in distinct(compact([for vm in values(local.selected_vms) : try(vm.ha.group, null)])) :
    g => sort([for name, vm in local.selected_vms : name if try(vm.ha.group, null) == g])
  }
}

resource "proxmox_harule" "spread" {
  for_each  = { for g, names in local.ha_groups : g => names if length(names) >= 2 && length(names) <= local.ha_cluster_node_count }
  rule      = "spread-${each.key}"
  type      = "resource-affinity"
  affinity  = "negative"
  comment   = "Managed by OpenTofu: ${join(", ", each.value)} on separate nodes"
  resources = [for name in each.value : module.vm[name].ha_resource_id]
}

check "ha_group_size" {
  assert {
    condition     = alltrue([for names in values(local.ha_groups) : length(names) <= local.ha_cluster_node_count])
    error_message = "HA groups with more VMs than cluster nodes (${local.ha_cluster_node_count}) get no spread rule: ${join(", ", [for g, names in local.ha_groups : g if length(names) > local.ha_cluster_node_count])}. Split them into smaller groups."
  }
}

output "ha_groups" {
  description = "HA groups and their VMs (each group's VMs are kept on separate nodes)."
  value       = local.ha_groups
}
