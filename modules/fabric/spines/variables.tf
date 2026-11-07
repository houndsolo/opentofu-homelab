variable "spine" {
  type = object({
    management_ip    = string
    id               = number
    uplink_interface = optional(string)
    as               = optional(number)
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
    error_message = "Leaf IDs must be unique so each spine has only one underlay/overlay connection pair per leaf."
  }
}

variable "keepalive_time" {
  description = "RouterOS BGP keepalive interval on both templates and every connection; use at most one third of hold_time."
  type        = string
  default     = "1m"
}

variable "hold_time" {
  description = "RouterOS BGP hold time on both templates and every connection."
  type        = string
  default     = "3m"
}
