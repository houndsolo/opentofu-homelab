variable "fabric" {
  description = "Example overlay settings and fabric members."
  type = object({
    overlay_as = number
    leaves = map(object({
      management_ip = string
      router_id = string
      vtep_ipv6 = string
    }))
    spines = map(object({
      management_ip = string
      router_id = string
      loopback_ipv6 = string
    }))
  })
  validation {
    condition = var.fabric.overlay_as >= 1 && var.fabric.overlay_as <= 4294967295 && floor(var.fabric.overlay_as) == var.fabric.overlay_as
    error_message = "overlay_as must be a valid integer ASN."
  }
}
