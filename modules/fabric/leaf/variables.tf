variable "name" {
  type = string
}
variable "leaf" {
  type = object({
    role             = string
    standalone       = optional(bool, false) # the standalone Proxmox host's leaf (greatfox)
    id               = number
    management_ip    = string # from modules/fabric/leaves
    access_interface = string
  })
}

variable "radius" {
  description = "RADIUS login for this leaf: servers + this leaf's shared secret (from roots/radius). null = not managed."
  type = object({
    servers = list(string)
    secret  = string
  })
  sensitive = true
  default   = null
}

variable "router_advert_routes" {
  description = "IPv6 routes (RFC 4191 route information) announced in the router advertisements of segments with router_advert = true: hosts reach them via the anycast gateway. The fabric's ULA space by default."
  type        = list(string)
  default     = ["fd69::/16"]
}
