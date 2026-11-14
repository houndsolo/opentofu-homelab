variable "name" {
  type = string
}
variable "leaf" {
  type = object({
    role             = string
    proxmox_node     = optional(string, null)
    standalone       = optional(bool, false) # the standalone Proxmox host's leaf (greatfox)
    id               = number
    access_interface = string
  })
}

variable "fabric_macs" {
  description = "Shared ethN -> MAC mappings used to bind guest interfaces to VM NICs."
  type        = map(string)
  default     = {}
}

variable "router_advert_routes" {
  description = "IPv6 routes (RFC 4191 route information) announced in the router advertisements of segments with router_advert = true: hosts reach them via the anycast gateway. The fabric's ULA space by default."
  type        = list(string)
  default     = ["fd69::/16"]
}
