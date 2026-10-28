nodes = {
  management_prefix = "10.20.7.0/24"
  cluster_api_node  = "fichina"
  proxmox = {
    fichina  = { id = 11 }
    macbeth  = { id = 12 }
    titania  = { id = 13 }
    zoness   = { id = 14 }
    fortuna  = { id = 15 }
    eldarad  = { id = 16 }
    venom    = { id = 17 }
    greatfox = { id = 20, standalone = true }
  }
}
