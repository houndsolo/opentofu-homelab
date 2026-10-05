variable "nodes" {
  description = "Shared Proxmox node inventory; IDs determine stable MACs."
  type        = map(object({ id = number }))
}

variable "underlay_bridges" {
  description = "Ordered bridges for eth1 onwards; eth0 is the management NIC."
  type        = list(string)
}

variable "underlay_local_as_base" {
  description = "Shared seed for the existing reference MAC formula."
  type        = number
}
