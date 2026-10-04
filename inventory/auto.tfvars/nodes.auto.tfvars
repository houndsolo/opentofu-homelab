nodes = {
  proxmox = {
    fichina = {
      id = 11
      cpu_cores = 8
    }
    macbeth = {
      id = 12
      cpu_cores = 12
    }
    titania = {
      id = 13
      cpu_cores = 8
    }
    zoness = {
      id = 14
      cpu_cores = 12
    }
    fortuna = {
      id = 15
      cpu_cores = 8
    }
    eldarad = {
      id = 16
      cpu_cores = 16
    }
    venom = {
      id = 17
      cpu_cores = 16
    }
  }
  proxmox_cluster = {
    pve = {
      endpoint_node = "venom"
    }
  }
}
