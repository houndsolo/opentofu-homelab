variable "fabric" {
  description = "Fabric addressing, AS numbers and members."
  type = object({
    settings = object({
      leaf_underlay_as_base    = number # Leaf underlay AS = base + leaf id.
      spine_as                 = number
      overlay_as               = number # iBGP EVPN AS shared by leaves and spines.
      loopback_ipv4_prefix     = string
      loopback_ipv6_prefix     = string
      loopback_interface       = string
      management_prefix        = string
      management_prefix_length = number
      l2_vni_base              = number
      vxlan_mtu                = optional(number, 9119)
      outer_mtu                = optional(number, 9189)
      ntp_servers              = optional(list(string), ["0.pool.ntp.org", "1.pool.ntp.org"])
      leaf_ntp_vrf             = optional(string) # VRF the leaf NTP client runs in; null = default VRF.
      # VyOS node-exporter (:9100) and frr-exporter (:9342) on each leaf's management
      # address, running in this VRF (null = default VRF). null = don't manage them.
      leaf_prometheus_exporters = optional(object({
        vrf = optional(string)
      }))
      # Remote syslog on every leaf (`system syslog remote`), RFC 5424 with the timezone;
      # TCP adds octet-counted framing. null = don't manage it.
      leaf_syslog = optional(object({
        host     = string           # the receiver, e.g. the Loki/Alloy VIP on the management network
        vrf      = optional(string) # VRF the leaf sends from; null = default VRF
        port     = optional(number, 514)
        protocol = optional(string, "tcp") # tcp or udp
        facility = optional(string, "all")
        level    = optional(string, "info")
      }))
      # Remote syslog on the RouterOS spines: the built-in "remote" logging action
      # (BSD/RFC 3164 over UDP, source address picked by the route) plus one logging
      # rule per topic. null = don't manage it.
      spine_syslog = optional(object({
        host     = string
        port     = optional(number, 514)
        facility = optional(string, "daemon")
        topics   = optional(list(string), ["info", "warning", "error", "critical"])
      }))
    })
    leaves = map(object({
      role             = string
      id               = number
      proxmox_node     = optional(string)
      access_interface = string
      spine_uplink     = optional(string)
    }))
    spines = map(object({
      management_ip    = string
      id               = number
      uplink_interface = optional(string)
      as               = optional(number) # Overrides settings.spine_as.
    }))
  })
  validation {
    condition = (
      var.fabric.settings.leaf_syslog == null ||
      contains(["tcp", "udp"], try(var.fabric.settings.leaf_syslog.protocol, ""))
    )
    error_message = "fabric.settings.leaf_syslog.protocol must be tcp or udp."
  }
}
