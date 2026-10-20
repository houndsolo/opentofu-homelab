variable "nodes" {
  description = "Shared node IDs, written as decimal-looking MAC octets (01..99)."
  type        = map(object({ id = number }))
  validation {
    condition = alltrue([
      for node in values(var.nodes) : node.id >= 1 && node.id <= 99 && node.id == floor(node.id)
    ]) && length(distinct([for node in values(var.nodes) : node.id])) == length(var.nodes)
    error_message = "Node IDs must be unique integers in 1..99 for the decimal-looking MAC format."
  }
}

variable "underlay_bridges" {
  description = "Ordered vmbr<number> bridges for eth1 onwards; management eth0 is excluded."
  type        = list(string)
  validation {
    condition = alltrue([
      for bridge in var.underlay_bridges : can(regex("^vmbr(0|[1-9][0-9]{0,3})$", bridge))
    ]) && length(var.underlay_bridges) <= 99 && length(distinct(var.underlay_bridges)) == length(var.underlay_bridges)
    error_message = "Use at most 99 unique vmbr<number> bridge names, with numbers in 0..9999 and no leading zeros."
  }
}
