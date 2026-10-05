variable "nodes" {
  description = "Proxmox hosts, keyed by their stable node names."
  type = object({
    proxmox = map(object({
      id              = number
      cpu_cores       = number
      network_profile = optional(string)
    }))
    proxmox_cluster = map(object({
      endpoint_node = string
    }))
  })
}
