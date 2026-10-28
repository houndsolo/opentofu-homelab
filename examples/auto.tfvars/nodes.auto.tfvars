# Keys must match actual PVE node names. IDs drive generated IPs, VM IDs and MACs.
# Keep IDs stable and unique (1..99 for the leaf MAC encoding).
nodes = {
  management_prefix = "10.20.7.0/24" # Host management IP = cidrhost(prefix, id).
  cluster_api_node  = "fichina"      # The default provider uses this node's API.
  proxmox = {
    fichina = { id = 11 }
    macbeth = { id = 12 }
    # At most one standalone (non-cluster) host, served by the greatfox provider alias.
    greatfox = { id = 20, standalone = true }
  }
}
