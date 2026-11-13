# Proxmox HA across the service VMs (ha.tf), against the real inventory (vms.auto.tfvars).
mock_provider "proxmox" {}

run "ha_groups" {
  command = plan
  assert {
    condition = (
      local.ha_groups.postgres == tolist(["pg01", "pg02", "pg03"]) && local.ha_groups.dns == tolist(["dns01", "dns02"]) &&
      length(local.ha_groups) == 11
    )
    error_message = "Every service role is an HA group (postgres = pg01-03, dns = dns01/02, ...)."
  }
  assert {
    condition = (
      proxmox_harule.spread["postgres"].rule == "spread-postgres" &&
      proxmox_harule.spread["postgres"].type == "resource-affinity" &&
      proxmox_harule.spread["postgres"].affinity == "negative" &&
      proxmox_harule.spread["postgres"].resources == toset(["vm:1140", "vm:1141", "vm:1142"]) &&
      proxmox_harule.spread["dns"].resources == toset(["vm:5301", "vm:5302"])
    )
    error_message = "Each HA group's VMs are kept on separate nodes by one negative resource-affinity rule."
  }
  assert {
    condition = alltrue([
      for g, names in local.ha_groups :
      length(distinct([for n in names : var.vms[n].node])) == length(names)
    ])
    error_message = "The inventory creates each HA group's VMs on separate nodes (otherwise HA would migrate one right away)."
  }
}

# A group larger than the cluster gets no rule (PVE would drop it as infeasible). With only two
# cluster nodes, the 3-VM groups (postgres, logging, metrics) lose their rule; pairs keep theirs.
run "ha_group_larger_than_cluster" {
  command = plan
  variables {
    nodes = {
      management_prefix = "10.20.7.0/24"
      cluster_api_node  = "fichina"
      proxmox = {
        fichina  = { id = 11 }
        macbeth  = { id = 12 }
        greatfox = { id = 20, standalone = true }
      }
    }
  }
  assert {
    condition = (
      local.ha_cluster_node_count == 2 &&
      !contains(keys(proxmox_harule.spread), "postgres") && !contains(keys(proxmox_harule.spread), "logging") &&
      contains(keys(proxmox_harule.spread), "dns") && length(local.ha_groups.postgres) == 3
    )
    error_message = "Groups with more VMs than cluster nodes get no spread rule; smaller groups keep theirs."
  }
  expect_failures = [check.ha_group_size]
}
