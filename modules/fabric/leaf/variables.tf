variable "name" {
  type = string
}
variable "overlay_as" {
  type = number
}
variable "leaf" {
  type = object({
    role          = string
    proxmox_node  = optional(string, null)
    id = number
  })
}

variable "fabric_macs" {
  description = "Shared ethN -> MAC mappings used to bind guest interfaces to VM NICs."
  type        = map(string)
  default     = {}
}
