variable "name" {
  description = "DHCP VM name from inventory."
  type        = string
}

variable "management_ip" {
  description = "DHCP VM OOB IPv4 address, without the CIDR prefix."
  type        = string
}

variable "interface_macs" {
  description = "Shared ethN -> MAC map from the same calculator used by VM creation. Excludes eth0."
  type        = map(string)
  default     = {}
}

variable "ha_prefix" {
  description = "HA peering prefix; peers use host addresses 1 and 2."
  type        = string
}

variable "ha" {
  description = "Pair identity derived from numeric VM-ID order; active-active mode is separate from identity."
  type = object({
    role                = string
    address_slot        = number
    peer_slot           = number
    peer_name           = string
    local_management_ip = string
    peer_management_ip  = string
  })
  default = null
}

variable "interface_addresses" {
  description = "VyOS data ethN -> static IPv4 CIDR. Management eth0 is excluded."
  type        = map(string)
  default     = {}
  validation {
    condition = alltrue([
      for interface, address in var.interface_addresses :
      can(regex("^eth[1-9][0-9]*$", interface)) && can(cidrnetmask(address))
    ])
    error_message = "Assign valid IPv4 CIDRs only to data ethN interfaces; eth0 is excluded."
  }
}

variable "default_name_servers" {
  description = "DNS servers advertised when a DHCP scope does not override name_servers."
  type        = list(string)
  default     = ["10.8.53.1", "10.8.53.2"]
}

variable "default_domain" {
  description = "DHCP domain-name/domain-search default."
  type        = string
  default     = "lylat.space"
}

variable "prometheus_exporters" {
  description = "VyOS node-exporter (:9100) and frr-exporter (:9342) on management_ip, in vrf (null = default VRF). null = don't manage them."
  type = object({
    vrf = optional(string)
  })
  default = null
}

variable "syslog" {
  description = "Remote syslog (`system syslog remote`) to every host in `hosts`, RFC 5424; TCP adds octet-counted framing. vrf null = default VRF. null = don't manage it."
  type = object({
    hosts    = list(string)
    vrf      = optional(string)
    port     = optional(number, 514)
    protocol = optional(string, "tcp")
    facility = optional(string, "all")
    level    = optional(string, "info")
  })
  default = null
  validation {
    condition     = var.syslog == null || (contains(["tcp", "udp"], try(var.syslog.protocol, "")) && length(try(var.syslog.hosts, [])) > 0)
    error_message = "syslog.protocol must be tcp or udp, and hosts must not be empty."
  }
}

variable "ha_interface" {
  description = "VyOS interface of the Kea HA NIC (its own L2VNI). Bound by hw-id and addressed, but Kea doesn't listen for clients there. null = none."
  type        = string
  default     = null
}
