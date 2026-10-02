variable "nodes" {
  description = "Proxmox hosts, keyed by their stable node names."
  type = map(object({
    management_ip = string
    network_profile = string
  }))
  validation {
    condition = alltrue([for node in values(var.nodes) : can(cidrhost("${node.management_ip}/32", 0))])
    error_message = "Each management_ip must be an IPv4 address."
  }
}
