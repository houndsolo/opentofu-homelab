variable "fabric" {
  description = "Fabric addressing, AS numbers and members."
  type = object({
    settings = object({
      underlay_as_base         = number # Underlay AS of every leaf and spine = base + its id (leaf-17 717, m326-1 701).
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
        hosts    = list(string)     # receivers, each gets every message: the logging VMs' own mgmt addresses
        vrf      = optional(string) # VRF the leaf sends from; null = default VRF
        port     = optional(number, 514)
        protocol = optional(string, "tcp") # tcp or udp
        facility = optional(string, "all")
        level    = optional(string, "info")
      }))
      # RADIUS login on every VyOS leaf (`system login radius`), against the FreeRADIUS pair. The servers and
      # each leaf's secret come from roots/radius (its generated radius-clients.secret.auto.tfvars); a leaf
      # without a secret there is left alone. VyOS keeps local users working (pam radius "optional" mode).
      # null = don't manage it.
      leaf_radius = optional(object({
        vrf = optional(string) # VRF the leaf reaches the servers from; null = default VRF
      }))
      # EXPERIMENT (branch ebgp-evpn, "option C"): EVPN on the unnumbered eBGP underlay session instead of a
      # separate iBGP loopback session, for these spine ids x leaf ids only. The spine's underlay connection
      # to such a leaf carries ipv6 + evpn with nexthop-choice=propagate and no output filter; the leaf drops
      # its loopback session to that spine and denies spine-learned routes (as-path _<spine AS>_) toward
      # the spines. null = off (every leaf/spine as on main).
      evpn_on_underlay = optional(object({
        spine_ids = list(number)
        leaf_ids  = list(number)
      }))
      # EXPERIMENT (branch ebgp-evpn, "option B"): leaf ids whose BGP instances (default + every VRF) use
      # system-as underlay_as_base + id instead of overlay_as (no local-as trick). These leaves peer
      # only with the evpn_on_underlay spines; their links to the other spines are disabled.
      leaf_own_as_ids = optional(list(number), [])
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
      access_interface = string
      spine_uplink     = optional(string)
    }))
    spines = map(object({
      management_ip    = string
      id               = number
      uplink_interface = optional(string)
    }))
  })
  validation {
    condition = (
      var.fabric.settings.leaf_syslog == null ||
      (contains(["tcp", "udp"], try(var.fabric.settings.leaf_syslog.protocol, "")) &&
      length(try(var.fabric.settings.leaf_syslog.hosts, [])) > 0)
    )
    error_message = "fabric.settings.leaf_syslog.protocol must be tcp or udp, and hosts must not be empty."
  }
}
