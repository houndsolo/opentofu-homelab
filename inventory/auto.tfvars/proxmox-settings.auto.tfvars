# Proxmox VE host-level settings (roots/proxmox-settings). Filled from the live settings on
# 2026-11-11 (GET /cluster/options, /nodes/<node>/dns, /nodes/<node>/time). An attribute left out
# (null) is not managed. Not manageable by the provider: tag-style, allowed-tags (edit in the UI).
# The bpg proxmox_cluster_options resource has no tag-style attribute and never sends or deletes it,
# so tofu leaves it alone. Set by hand on 2026-11-11 (cluster and greatfox, pvesh as root):
#   ordering=config (show tags in config order: opentofu tag, OS tag, function tags) and color-map
#   with vyos=yellow, opentofu=purple, debian=dark red, nixos=blue, grafana=orange, netbox=green.
#   Full value: tmp/agents/pve-tags.md.
proxmox_settings = {
  datacenter = {
    # The lylat cluster (datacenter.cfg, through fichina's API).
    cluster = {
      keyboard    = "en-us"
      language    = "en"
      mac_prefix  = "BC:24:11"
      max_workers = 7
      next_id     = { lower = 100, upper = 999999999 }

      migration_type = "secure"
      migration_cidr = "10.22.0.0/16"

      ha_shutdown_policy           = "migrate" # a node shutdown live-migrates its HA VMs away
      crs_ha                       = "dynamic" # place HA resources by current load (PVE 9.2+)
      crs_ha_rebalance_on_start    = true
      crs_ha_auto_rebalance        = true
      crs_ha_auto_rebalance_method = "topsis"
    }
    # greatfox (standalone host, its own datacenter.cfg).
    greatfox = {
      keyboard   = "en-us"
      mac_prefix = "BC:24:11"
    }
  }

  # Every host (cluster nodes and greatfox).
  dns = {
    domain  = "lylat.space"
    servers = ["10.8.53.53", "1.1.1.1"]
  }
  time_zone = "America/New_York"

  # Per-host overrides, e.g. nodes = { greatfox = { time_zone = "UTC" } }
  nodes = {}
}
