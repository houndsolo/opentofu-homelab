variable "l2vnis" {
  description = <<-EOT
    Standalone L2VNIs: pure bridged segments with no VRF, no SVI/anycast gateway and no DHCP.
    Used for unicast HA peer traffic (VRRP adverts, Kea HA, memberlist, alerting gossip).
    They go only to leaves whose role is in `roles` (default: the Proxmox hosts' virtual leaves,
    never the border leaves), and not to the standalone host's leaf unless `on_standalone`.
    `prefix` is not configured on the fabric; it is the source of truth for the hosts on the segment.
  EOT
  default     = {}
  type = map(object({
    vni         = number
    vlan_id     = number
    prefix      = string
    description = optional(string, "")
    roles       = optional(set(string), ["proxmox"])
    # Also on the standalone host's leaf (greatfox, not in the cluster). Off by default: the HA
    # segments only connect VMs on the cluster nodes.
    on_standalone = optional(bool, false)
  }))

  validation {
    condition = alltrue([
      for l2 in values(var.l2vnis) :
      l2.vni >= 1 && l2.vni <= 16777215 && l2.vni == floor(l2.vni) &&
      l2.vlan_id >= 1 && l2.vlan_id <= 4094 && l2.vlan_id == floor(l2.vlan_id) &&
      can(cidrhost(l2.prefix, 0)) && !strcontains(l2.prefix, ":") &&
      length(l2.roles) > 0 &&
      alltrue([for role in l2.roles : contains(["proxmox", "external_l2", "external_l3"], role)])
    ])
    error_message = "L2VNIs need an integer VNI 1..16777215, VLAN 1..4094, an IPv4 CIDR prefix and a nonempty set of valid leaf roles."
  }

  validation {
    condition = (
      length(distinct([for l2 in values(var.l2vnis) : l2.vni])) == length(var.l2vnis) &&
      length(distinct([for l2 in values(var.l2vnis) : l2.vlan_id])) == length(var.l2vnis)
    )
    error_message = "Standalone L2VNI VNIs and VLAN IDs must be unique (overlap with var.vnis is checked where both are used)."
  }
}
