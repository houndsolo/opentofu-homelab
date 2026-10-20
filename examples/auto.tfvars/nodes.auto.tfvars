# Keys must match actual PVE node names. IDs drive generated IPs, VM IDs and MACs.
# Keep IDs stable and unique (1..99 for the leaf MAC encoding).
nodes = {
  proxmox_cluster = {
    fichina = { id = 11, cpu_cores = 16 }
    macbeth = { id = 12, cpu_cores = 16 }
  }
  # Standalone PVE hosts. Existing provider routing specifically supports greatfox.
  proxmox = {
    greatfox = { id = 20, cpu_cores = 8 }
  }
}
