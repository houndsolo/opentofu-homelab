variable "records" {
  description = "Extra lylat.space records, keyed by relative hostname. Omit unused types."
  type = map(object({
    a     = optional(string)
    aaaa  = optional(string)
    cname = optional(string)
  }))
  default = {}

  validation {
    condition = alltrue([
      for name in keys(var.records) : can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*$", name))
    ])
    error_message = "Record names must be lowercase relative hostnames, such as host01 or app.host01."
  }
  validation {
    condition = alltrue([
      for record in values(var.records) :
      record.cname != null ? (record.a == null && record.aaaa == null) : (record.a != null || record.aaaa != null)
    ])
    error_message = "Set a and/or aaaa, or set cname alone. A CNAME cannot share its name with address records."
  }
  validation {
    condition = alltrue([
      for record in values(var.records) :
      (record.a == null ? true : !strcontains(record.a, ":") && can(cidrhost("${record.a}/32", 0))) &&
      (record.aaaa == null ? true : strcontains(record.aaaa, ":") && can(cidrhost("${record.aaaa}/128", 0))) &&
      (record.cname == null ? true : can(regex("^[a-zA-Z0-9][a-zA-Z0-9.-]*\\.$", record.cname)))
    ])
    error_message = "Use plain IPv4/IPv6 addresses and a fully qualified CNAME target ending in a dot."
  }
  validation {
    condition = length(setintersection(toset(keys(var.records)), toset(concat(
      keys(var.nodes.proxmox), keys(var.nodes.proxmox_cluster), keys(var.network_services.dns),
    )))) == 0
    error_message = "Proxmox node and DNS server names are generated automatically; do not redefine them in records."
  }
}
