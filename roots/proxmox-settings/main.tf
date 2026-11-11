# Proxmox VE host-level settings (inventory/auto.tfvars/proxmox-settings.auto.tfvars):
# datacenter options of the cluster and of the standalone host, and every host's DNS and time zone.
# The existing settings are adopted with import blocks (imports.tf).

locals {
  standalone     = one([for name, node in var.nodes.proxmox : name if node.standalone])
  cluster_nodes  = sort([for name, node in var.nodes.proxmox : name if !node.standalone])
  datacenter     = var.proxmox_settings.datacenter
  dc_cluster     = lookup(local.datacenter, "cluster", null)
  dc_standalone  = local.standalone == null ? null : lookup(local.datacenter, local.standalone, null)
  node_dns       = { for name in keys(var.nodes.proxmox) : name => coalesce(try(var.proxmox_settings.nodes[name].dns, null), var.proxmox_settings.dns) }
  node_time_zone = { for name in keys(var.nodes.proxmox) : name => coalesce(try(var.proxmox_settings.nodes[name].time_zone, null), var.proxmox_settings.time_zone) }
  cluster_dns    = { for name in local.cluster_nodes : name => local.node_dns[name] }
  standalone_dns = local.standalone == null ? {} : { (local.standalone) = local.node_dns[local.standalone] }
}

check "datacenter_keys" {
  assert {
    condition     = alltrue([for k in keys(local.datacenter) : k == "cluster" || k == local.standalone])
    error_message = "proxmox_settings.datacenter keys are \"cluster\" or the standalone host's name (${coalesce(local.standalone, "none")})."
  }
}

# --- datacenter options (datacenter.cfg) -------------------------------------------------------

resource "proxmox_cluster_options" "cluster" {
  count = local.dc_cluster == null ? 0 : 1

  keyboard                            = local.dc_cluster.keyboard
  language                            = local.dc_cluster.language
  console                             = local.dc_cluster.console
  description                         = local.dc_cluster.description
  email_from                          = local.dc_cluster.email_from
  http_proxy                          = local.dc_cluster.http_proxy
  mac_prefix                          = local.dc_cluster.mac_prefix
  max_workers                         = local.dc_cluster.max_workers
  next_id                             = local.dc_cluster.next_id
  bandwidth_limit_clone               = local.dc_cluster.bandwidth_limit_clone
  bandwidth_limit_default             = local.dc_cluster.bandwidth_limit_default
  bandwidth_limit_migration           = local.dc_cluster.bandwidth_limit_migration
  bandwidth_limit_move                = local.dc_cluster.bandwidth_limit_move
  bandwidth_limit_restore             = local.dc_cluster.bandwidth_limit_restore
  migration_type                      = local.dc_cluster.migration_type
  migration_cidr                      = local.dc_cluster.migration_cidr
  ha_shutdown_policy                  = local.dc_cluster.ha_shutdown_policy
  crs_ha                              = local.dc_cluster.crs_ha
  crs_ha_rebalance_on_start           = local.dc_cluster.crs_ha_rebalance_on_start
  crs_ha_auto_rebalance               = local.dc_cluster.crs_ha_auto_rebalance
  crs_ha_auto_rebalance_method        = local.dc_cluster.crs_ha_auto_rebalance_method
  crs_ha_auto_rebalance_threshold     = local.dc_cluster.crs_ha_auto_rebalance_threshold
  crs_ha_auto_rebalance_margin        = local.dc_cluster.crs_ha_auto_rebalance_margin
  crs_ha_auto_rebalance_hold_duration = local.dc_cluster.crs_ha_auto_rebalance_hold_duration
  notify                              = local.dc_cluster.notify
}

resource "proxmox_cluster_options" "standalone" {
  count    = local.dc_standalone == null ? 0 : 1
  provider = proxmox.greatfox

  keyboard                            = local.dc_standalone.keyboard
  language                            = local.dc_standalone.language
  console                             = local.dc_standalone.console
  description                         = local.dc_standalone.description
  email_from                          = local.dc_standalone.email_from
  http_proxy                          = local.dc_standalone.http_proxy
  mac_prefix                          = local.dc_standalone.mac_prefix
  max_workers                         = local.dc_standalone.max_workers
  next_id                             = local.dc_standalone.next_id
  bandwidth_limit_clone               = local.dc_standalone.bandwidth_limit_clone
  bandwidth_limit_default             = local.dc_standalone.bandwidth_limit_default
  bandwidth_limit_migration           = local.dc_standalone.bandwidth_limit_migration
  bandwidth_limit_move                = local.dc_standalone.bandwidth_limit_move
  bandwidth_limit_restore             = local.dc_standalone.bandwidth_limit_restore
  migration_type                      = local.dc_standalone.migration_type
  migration_cidr                      = local.dc_standalone.migration_cidr
  ha_shutdown_policy                  = local.dc_standalone.ha_shutdown_policy
  crs_ha                              = local.dc_standalone.crs_ha
  crs_ha_rebalance_on_start           = local.dc_standalone.crs_ha_rebalance_on_start
  crs_ha_auto_rebalance               = local.dc_standalone.crs_ha_auto_rebalance
  crs_ha_auto_rebalance_method        = local.dc_standalone.crs_ha_auto_rebalance_method
  crs_ha_auto_rebalance_threshold     = local.dc_standalone.crs_ha_auto_rebalance_threshold
  crs_ha_auto_rebalance_margin        = local.dc_standalone.crs_ha_auto_rebalance_margin
  crs_ha_auto_rebalance_hold_duration = local.dc_standalone.crs_ha_auto_rebalance_hold_duration
  notify                              = local.dc_standalone.notify
}

# --- per-host DNS and time zone ---------------------------------------------------------------

resource "proxmox_virtual_environment_dns" "cluster" {
  for_each  = local.cluster_dns
  node_name = each.key
  domain    = each.value.domain
  servers   = each.value.servers
}

resource "proxmox_virtual_environment_dns" "standalone" {
  for_each  = local.standalone_dns
  provider  = proxmox.greatfox
  node_name = each.key
  domain    = each.value.domain
  servers   = each.value.servers
}

resource "proxmox_virtual_environment_time" "cluster" {
  for_each  = toset(local.cluster_nodes)
  node_name = each.key
  time_zone = local.node_time_zone[each.key]
}

resource "proxmox_virtual_environment_time" "standalone" {
  for_each  = local.standalone == null ? toset([]) : toset([local.standalone])
  provider  = proxmox.greatfox
  node_name = each.key
  time_zone = local.node_time_zone[each.key]
}

output "settings" {
  description = "Effective DNS and time zone per host."
  value       = { for name in keys(var.nodes.proxmox) : name => { dns = local.node_dns[name], time_zone = local.node_time_zone[name] } }
}
