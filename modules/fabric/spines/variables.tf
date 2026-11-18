variable "spine" {
  description = "This spine's fabric.spines entry; only the id is used here (the root's provider has the address)."
  type = object({
    id = number
  })
}

variable "leaves" {
  description = "Leaves connected to this spine, keyed by name. Each entry carries `spine_uplink`: the spine-side interface for the p2p link, or null when the default ether<leaf id> applies."
  type = map(object({
    id           = number
    spine_uplink = optional(string, null)
  }))

  validation {
    condition     = length(distinct([for leaf in values(var.leaves) : leaf.id])) == length(var.leaves)
    error_message = "Leaf IDs must be unique so each spine has only one BGP connection per leaf."
  }
}

variable "keepalive_time" {
  description = "RouterOS BGP keepalive interval on the template and every connection; use at most one third of hold_time."
  type        = string
  default     = "1m"
}

variable "hold_time" {
  description = "RouterOS BGP hold time on the template and every connection."
  type        = string
  default     = "3m"
}

variable "port_mtu" {
  description = "L3 MTU of the leaf-facing ports (above the leaves' outer_mtu 9189, room for VXLAN)."
  type        = number
  default     = 10000
}

variable "port_l2mtu" {
  description = "L2 MTU of the leaf-facing ports (CRS326 maximum)."
  type        = number
  default     = 10218
}

variable "switch_name" {
  description = "The switch chip whose L3 hardware offload routes the underlay."
  type        = string
  default     = "switch1"
}
