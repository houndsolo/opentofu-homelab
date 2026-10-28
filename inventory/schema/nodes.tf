variable "nodes" {
  description = "Proxmox hosts, keyed by their stable node names, and how to reach them."
  type = object({
    management_prefix = string # Host management IP = cidrhost(prefix, id).
    cluster_api_node  = string # Cluster node whose API the default provider uses.
    proxmox = map(object({
      id = number
      # Outside the cluster; managed through the greatfox provider alias.
      standalone = optional(bool, false)
    }))
  })
  validation {
    condition     = length([for node in values(var.nodes.proxmox) : node if node.standalone]) <= 1
    error_message = "Only one standalone host is supported; it uses the greatfox provider alias."
  }
  validation {
    condition     = contains([for name, node in var.nodes.proxmox : name if !node.standalone], var.nodes.cluster_api_node)
    error_message = "cluster_api_node must name a non-standalone host."
  }
  validation {
    condition     = length(distinct([for node in values(var.nodes.proxmox) : node.id])) == length(var.nodes.proxmox)
    error_message = "Proxmox node IDs must be unique; they derive IPs, VM IDs and MACs."
  }
}
