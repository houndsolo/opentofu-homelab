variable "backend" {
  description = "The one monitoring backend VM (Prometheus, Alertmanager, exporters, InfluxDB, Postgres)."
  type = object({
    name               = string
    monitoring_address = string # Monitoring network (10.5/16): UIs, PVE metric pushes, node_exporter.
    backend_address    = string # Isolated backend VLAN (10.13/16): Grafana -> datasources and Postgres.
  })
}

variable "grafana" {
  description = "Grafana front ends, keyed by VM name. backend_address is the VM's address on the backend VLAN; ha_address on the Grafana HA VLAN (alerting gossip, VRRP), and interfaces the VM's NIC names for VRRP (ha, and vip: the UI NIC that holds grafana_vrrp.vip)."
  type = map(object({
    backend_address = string
    ha_address      = optional(string) # null on any VM: gossip stays on the backend and no keepalived
    interfaces = optional(object({
      ha  = string
      vip = string
    }))
  }))
}

variable "grafana_vrrp" {
  description = "keepalived VIP for Grafana (CIDR on the UI NIC), VRRP router id and PASS password (8 characters at most). Needs ha_address/interfaces on every Grafana VM and at least two VMs. null = no keepalived."
  type = object({
    vip       = string
    router_id = optional(number, 11)
    auth_pass = string
  })
  default = null
  validation {
    condition     = var.grafana_vrrp == null || try(can(cidrhost(var.grafana_vrrp.vip, 0)) && var.grafana_vrrp.router_id >= 1 && var.grafana_vrrp.router_id <= 255 && length(var.grafana_vrrp.auth_pass) <= 8, false)
    error_message = "grafana_vrrp needs vip as an IPv4 CIDR, router_id 1..255 and auth_pass of at most 8 characters."
  }
}

variable "images" {
  description = "Container images. Pin exact tags (or digests) for reproducible deployments."
  type = object({
    prometheus        = string
    alertmanager      = string
    node_exporter     = string
    snmp_exporter     = string
    blackbox_exporter = string
    pve_exporter      = string
    influxdb          = string
    postgres          = string
    grafana           = string
    loki              = string
    alloy             = string
    haproxy           = string
  })
  validation {
    condition     = alltrue([for image in values(var.images) : can(regex("^[A-Za-z0-9][A-Za-z0-9._/:@-]*$", image))])
    error_message = "Use container image references without whitespace or shell characters."
  }
}

variable "targets" {
  description = "Prometheus scrape targets. Addresses are bare IPs unless noted; ports are added per job."
  type = object({
    node     = list(object({ host = string, address = string, labels = optional(map(string), {}) })) # node_exporter, :9100
    vyos     = list(object({ host = string, address = string, labels = optional(map(string), {}) })) # VyOS node (:9100) and FRR (:9342) exporters
    pve      = list(object({ host = string, address = string }))                                     # PVE API via pve-exporter
    grafana  = list(object({ host = string, address = string }))                                     # Grafana /metrics, :3000
    ceph     = optional(list(object({ host = string, address = string })), [])                       # Ceph mgr prometheus module, :9283 (every mgr host)
    telegraf = optional(list(object({ host = string, address = string })), [])                       # Telegraf prometheus-client output on VyOS routers, :9273
    snmp     = map(object({ modules = list(string), auth = string, targets = map(string) }))         # job suffix => host => IP
    blackbox = map(list(object({ host = string, target = string })))                                 # blackbox module => targets (IP or URL)
  })
}

variable "secrets" {
  description = "Generated credentials. InfluxDB and Postgres read theirs only when their data directories are first initialised."
  sensitive   = true
  type = object({
    influxdb_admin_password = string
    influxdb_admin_token    = string
    grafana_db_password     = string
    grafana_admin_password  = string
    grafana_secret_key      = string
  })
}

variable "pve_exporter_token" {
  description = "Read-only PVE API token (PVEAuditor) for pve-exporter. null leaves pve-exporter and its job out."
  sensitive   = true
  type = object({
    user       = string
    token_name = string
    value      = string
  })
  default = null
}

variable "snmp_auths" {
  description = "Extra snmp_exporter auths (SNMPv3), name => credentials, added to the bundled snmp.yml through a second config file. Reference a name as an snmp target's auth."
  sensitive   = true
  type = map(object({
    username       = string
    security_level = optional(string, "authPriv")
    auth_protocol  = optional(string, "SHA")
    password       = string
    priv_protocol  = optional(string, "AES")
    priv_password  = string
  }))
  default = {}
}

variable "settings" {
  description = "Retention, external URLs and InfluxDB naming."
  type = object({
    prometheus_retention_time = optional(string, "90d")
    prometheus_retention_size = optional(string, "120GB")
    influxdb_org              = optional(string, "lylat")
    influxdb_bucket           = optional(string, "proxmox")     # created by InfluxDB setup on first start only
    influxdb_grafana_bucket   = optional(string, "pve_cluster") # default bucket of the Grafana InfluxDB datasource
    influxdb_retention        = optional(string, "90d")
    grafana_root_url          = optional(string, "http://grafana.lylat.space:3000/")
    dns_probe_zone            = optional(string, "lylat.space")
    ceph_cluster_name         = optional(string, "lylat") # cluster label on ceph metrics (ceph-mixin dashboards filter on it)
  })
  default = {}
}

variable "logging" {
  description = "Logging VMs (Loki ring, Alloy syslog receiver, haproxy to the RGWs, keepalived), keyed by VM name. Name order sets the VRRP priority (150, 100, 50). Empty leaves logging out; Alloy (journal) still runs on the backend and Grafana VMs."
  type = map(object({
    backend_address    = string # backend VLAN: Loki HTTP API (Grafana, Alloy pushes), scrapes
    ha_address         = string # HA VLAN: Loki ring (memberlist, ingester gRPC) and VRRP adverts
    monitoring_address = string # monitoring network: syslog from devices and PVE nodes
    mgmt_address       = string # management network: syslog from the VyOS leaves/DHCP VMs (mgmt VRF)
    interfaces = object({       # the VM's interface name on each of those networks (VRRP)
      ha         = string
      backend    = string
      monitoring = string
      mgmt       = string
    })
  }))
  default = {}
}

variable "logging_settings" {
  description = "VIPs (CIDR, one per client network, all in one VRRP instance), VRRP router id, the Ceph RGW endpoints behind each VM's haproxy, Loki retention and replication, the schema's start date and which sources may reach Loki's ports."
  type = object({
    vips = optional(object({
      backend    = optional(string, "10.13.11.40/16") # Grafana datasource, Alloy pushes from the other VMs
      monitoring = optional(string, "10.5.11.40/16")  # syslog from devices and PVE nodes
      mgmt       = optional(string, "10.20.11.40/16") # syslog from the VyOS leaves and DHCP VMs (mgmt VRF)
    }), {})
    vrrp_router_id        = optional(number, 40)
    rgw_endpoints         = optional(list(string), ["10.27.0.12:7480", "10.27.0.13:7480", "10.27.0.17:7480"])
    retention_period      = optional(string, "90d")
    replication_factor    = optional(number, 3)
    schema_start          = optional(string, "2026-11-01")           # never change once Loki has data; add a new period instead
    loki_allowed_sources  = optional(list(string), ["10.13.0.0/16"]) # Loki HTTP (3100); the ring ports only accept the logging VMs
    syslog_host_overrides = optional(map(string), {})                # sender IP => host label
  })
  default = {}
  validation {
    condition     = length(var.logging_settings.rgw_endpoints) > 0 && alltrue([for e in var.logging_settings.rgw_endpoints : can(regex("^[0-9.]+:[0-9]+$", e))])
    error_message = "rgw_endpoints are \"IP:port\" strings, at least one."
  }
}

variable "logging_secrets" {
  description = "Loki's S3 bucket and keys (RGW user) and the VRRP password (8 characters at most, VRRPv2 PASS). Required when logging is non-empty."
  sensitive   = true
  type = object({
    s3_bucket     = string
    s3_access_key = string
    s3_secret_key = string
    vrrp_password = string
  })
  default = null
}
