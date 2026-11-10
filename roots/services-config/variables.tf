variable "ssh_private_key_path" {
  description = "Local private key authorized for each DNS VM's config.ssh_username."
  type        = string
  default     = "~/.ssh/id_rsa"
}

variable "bind9_image" {
  description = "ISC BIND9 image. Pin a digest here for reproducible deployments."
  type        = string
  default     = "docker.io/internetsystemsconsortium/bind9:9.20"
  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9._/:@-]*$", var.bind9_image))
    error_message = "Use a container image reference without whitespace or shell characters."
  }
}

variable "dns_allowed_clients" {
  description = "IPv4 client networks permitted to query and use recursion."
  type        = list(string)
  default     = ["127.0.0.1/32", "10.0.0.0/8"]
  validation {
    condition     = length(var.dns_allowed_clients) > 0 && alltrue([for prefix in var.dns_allowed_clients : can(cidrnetmask(prefix))])
    error_message = "Provide at least one valid IPv4 CIDR."
  }
}

variable "dns_deploy_revision" {
  description = "Change to redeploy after rebuilding a VM without changing its address or ID."
  type        = string
  default     = "1"
}

variable "dns_hosts" {
  description = "Zone-relative owner => supported record type => value. TXT is plain text; MX and SRV use space-separated fields. Overrides generated records for that owner."
  type        = map(map(string))
  default     = {}
  validation {
    condition = alltrue(flatten([
      for owner, records in var.dns_hosts : [
        for type, data in records :
        can(regex("^(@|[A-Za-z0-9_*][A-Za-z0-9_.*-]*)$", owner)) &&
        contains(["A", "AAAA", "CNAME", "TXT", "MX", "NS", "PTR", "SRV"], type) &&
        !(owner == "@" && type == "NS") &&
        !(contains(keys(local.dns_vms), lower(trimsuffix(owner, "."))) && type == "A") &&
        (type != "MX" || can(regex("^[0-9]+\\s+[^\\s]+\\.$", data))) &&
        (type != "SRV" || can(regex("^[0-9]+\\s+[0-9]+\\s+[0-9]+\\s+[^\\s]+\\.$", data))) &&
        !can(regex("[\r\n]", data)) && trimspace(data) != ""
      ]
    ]))
    error_message = "Use relative owners, supported uppercase types and single-line values. Apex NS and DNS-server A records are bootstrap-owned."
  }
}

variable "dns_records" {
  description = "Additional records with repeated owner/type pairs and per-record TTLs. Supports A, AAAA, CNAME, TXT, MX, NS, PTR and SRV."
  type = list(object({
    name = string
    type = string
    data = string
    ttl  = optional(number, 300)
  }))
  default = []
  validation {
    condition = alltrue([
      for record in var.dns_records :
      can(regex("^(@|[A-Za-z0-9_*][A-Za-z0-9_.*-]*)$", record.name)) &&
      contains(["A", "AAAA", "CNAME", "TXT", "MX", "NS", "PTR", "SRV"], record.type) &&
      !(record.name == "@" && record.type == "NS") &&
      !(contains(keys(local.dns_vms), lower(trimsuffix(record.name, "."))) && record.type == "A") &&
      (record.type != "MX" || can(regex("^[0-9]+\\s+[^\\s]+\\.$", record.data))) &&
      (record.type != "SRV" || can(regex("^[0-9]+\\s+[0-9]+\\s+[0-9]+\\s+[^\\s]+\\.$", record.data))) &&
      !can(regex("[\r\n]", record.data)) && trimspace(record.data) != "" &&
      record.ttl >= 0 && record.ttl <= 2147483647 && record.ttl == floor(record.ttl)
    ])
    error_message = "Records need a relative owner, supported type, single-line value and integer TTL. Apex NS and DNS-server A records are bootstrap-owned."
  }
  validation {
    condition = alltrue([
      for record in var.dns_records : alltrue([
        for peer in concat(local.host_records, var.dns_records) :
        lower(trimsuffix(record.name, ".")) == lower(trimsuffix(peer.name, ".")) && record.type == peer.type ? (
          record.ttl == peer.ttl && (!contains(["CNAME", "PTR"], record.type) || record.data == peer.data)
        ) : true
      ])
    ])
    error_message = "Use one TTL per owner/type RRset, and only one target for CNAME or PTR."
  }

}

variable "dns_primary" {
  description = "Inventory hostname of the writable primary; other DNS VMs are secondaries."
  type        = string
  default     = "dns01"
}

variable "dns_tsig_secret" {
  description = "Optional existing base64 HMAC-SHA256 key. When null, generate 32 random bytes once and retain them in state."
  type        = string
  sensitive   = true
  default     = null
  validation {
    condition     = var.dns_tsig_secret == null || can(regex("^[A-Za-z0-9+/]{43}=$", var.dns_tsig_secret))
    error_message = "Supply a base64-encoded 32-byte HMAC-SHA256 key, e.g. openssl rand -base64 32."
  }
}

variable "dns_vrrp" {
  description = <<-EOT
    keepalived VIP for the DNS pair. Adverts go unicast over the HA L2VNI (l2vnis.ha_dns, the NIC on
    that VLAN); the VIP sits on BIND's service NIC (the one with the gateway). BIND also listens on the
    VIP, and DHCP hands it out as the first name server. null = no keepalived/VIP.
  EOT
  type = object({
    vip       = string
    router_id = optional(number, 53)
  })
  default = {
    vip = "10.8.53.53/16"
  }
  validation {
    condition = var.dns_vrrp == null || try(
      can(cidrhost(var.dns_vrrp.vip, 0)) && strcontains(var.dns_vrrp.vip, "/") &&
      var.dns_vrrp.router_id >= 1 && var.dns_vrrp.router_id <= 255, false
    )
    error_message = "dns_vrrp.vip must be an IPv4 address with prefix length (e.g. 10.8.53.53/16), router_id 1..255."
  }
}

variable "dhcp_prometheus_exporters" {
  description = "VyOS node-exporter/frr-exporter on each DHCP VM's management address, in this VRF (scraped by monitoring-config). null = don't manage them."
  type = object({
    vrf = optional(string)
  })
  default = { vrf = "mgmt" }
}

variable "dhcp_syslog" {
  description = "Remote syslog from each DHCP VM (RFC 5424 over TCP by default), sent from this VRF. Default: the Loki/Alloy VIP on the management network (monitoring-config). null = don't manage it."
  type = object({
    host     = string
    vrf      = optional(string)
    port     = optional(number, 514)
    protocol = optional(string, "tcp")
    facility = optional(string, "all")
    level    = optional(string, "info")
  })
  default = { host = "10.20.11.101", vrf = "mgmt" }
}

variable "dns_syslog" {
  description = "Forward each DNS VM's journal (BIND included) with rsyslog to this syslog receiver over TCP (RFC 5424, octet-counted), from the management network. Default: the Loki/Alloy VIP (monitoring-config). null = don't install it."
  type = object({
    host  = string
    port  = optional(number, 514)
    level = optional(string, "info")
  })
  default = { host = "10.20.11.101" }
  validation {
    condition = var.dns_syslog == null || (
      can(regex("^[A-Za-z0-9.:-]+$", try(var.dns_syslog.host, ""))) &&
      contains(["debug", "info", "notice", "warning", "err", "crit", "alert", "emerg"], try(var.dns_syslog.level, ""))
    )
    error_message = "dns_syslog.host must be a plain host name or address and level a syslog severity."
  }
}
