nodes = {
  proxmox = {
    fichina = {
      id = 11
      cpu_cores = 8
      network_profile = "default"
    }
    macbeth = {
      id = 12
      cpu_cores = 12
      network_profile = "default"
    }
    titania = {
      id = 13
      cpu_cores = 8
      network_profile = "default"
    }
    zoness = {
      id = 14
      cpu_cores = 12
      network_profile = "default"
    }
    fortuna = {
      id = 15
      cpu_cores = 8
      network_profile = "default"
    }
    eldarad = {
      id = 16
      cpu_cores = 16
      network_profile = "default"
    }
    venom = {
      id = 17
      cpu_cores = 16
      network_profile = "default"
    }
  }
  proxmox_cluster = {
    pve = {
      endpoint_node = "venom"
    }
  }
}
