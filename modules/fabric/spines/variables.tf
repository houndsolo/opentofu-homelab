variable "name" {
  type = string
}

variable "spine" {
  type = object({
    management_ip = string
    id            = number
    uplink_if     = optional(string)
    as            = optional(number)
  })
}

variable "leaves" {
  description = "Leaves connected to this spine, keyed by name. Each entry carries `spine_uplink`: the spine-side interface for the p2p link, or null when the default ether<leaf id> applies."
  type = map(object({
    id           = number
    spine_uplink = optional(string, null)
  }))
}
