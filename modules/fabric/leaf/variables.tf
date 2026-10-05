variable "name" {
  type = string
}
variable "overlay_as" {
  type = number
}
variable "leaf" {
  type = object({
    role          = optional(string, "generic")
    proxmox_node  = optional(string)
    management_ip = string
    router_id     = string
    vtep_ipv6     = string
  })
}

variable "fabric_macs" {
  description = "Shared ethN -> MAC mappings used to bind guest interfaces to VM NICs."
  type        = map(string)
  default     = {}
}
