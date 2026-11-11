# Proxmox HA across the service VMs (ha.tf), against the real inventory (vms.auto.tfvars).
mock_provider "proxmox" {}

run "ha_groups" {
  command = plan
  assert {
    condition = (
      local.ha_groups.postgres == tolist(["pg01", "pg02", "pg03"]) && local.ha_groups.dns == tolist(["dns01", "dns02"]) &&
      length(local.ha_groups) == 8
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
