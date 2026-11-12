variable "vips" {
  description = <<-EOT
    Every keepalived VIP in the lab, keyed by its DNS name (zone-relative: the key "netbox" is
    netbox.lylat.space). services-config publishes an A record (and the PTR) for each one;
    monitoring-config and services-config check that the services' own VIP settings match
    this list, so a VIP or VRID is defined once and can't silently drift or collide.
    - address: the VIP with its prefix length, as keepalived configures it.
    - vrid:    the VRRP router id (also the last byte of the VMAC, 00:00:5e:00:01:<vrid>). One VRRP
               instance can hold several VIPs, so a VRID may appear more than once, but only for one role.
    - role:    the role of the VMs that hold it (vms.<name>.role).
  EOT
  type = map(object({
    address     = string
    vrid        = number
    role        = string
    description = optional(string, "")
  }))
  default = {}

  validation {
    condition = alltrue([
      for name, vip in var.vips :
      can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$", name)) &&
      can(cidrhost(vip.address, 0)) && strcontains(vip.address, "/") && !strcontains(vip.address, ":") &&
      vip.vrid >= 1 && vip.vrid <= 255 && vip.vrid == floor(vip.vrid)
    ])
    error_message = "VIP names are lowercase DNS names; address is an IPv4 address with prefix length (10.2.11.106/16); vrid is 1..255."
  }

  validation {
    condition     = length(distinct([for vip in values(var.vips) : split("/", vip.address)[0]])) == length(var.vips)
    error_message = "Every VIP address must be unique."
  }

  validation {
    condition = alltrue([
      for vrid in distinct([for vip in values(var.vips) : vip.vrid]) :
      length(distinct([for vip in values(var.vips) : vip.role if vip.vrid == vrid])) == 1
    ])
    error_message = "A VRID belongs to one role's VRRP instance: two roles can't share a VRID (their VMACs would collide)."
  }
}
