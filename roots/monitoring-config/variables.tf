variable "ssh_private_key_path" {
  description = "Local private key authorized for each monitoring/grafana VM's config.ssh_username."
  type        = string
  default     = "~/.ssh/id_rsa"
}

variable "deploy_revision" {
  description = "Change to redeploy after rebuilding a VM without changing its address, ID or rendered files."
  type        = string
  default     = "1"
}

variable "backend_vlan_id" {
  description = "VLAN of the isolated monitoring backend (lylat_monitor VRF). The monitoring and grafana VMs each need one addressed NIC on it."
  type        = number
  default     = 13
}

variable "ha_vlan_id" {
  description = "HA VLAN of the logging VMs (L2VNI ha_logging): Loki's ring (memberlist, ingester gRPC) and keepalived's unicast adverts. Each logging VM needs one addressed NIC on it."
  type        = number
  default     = 214
}

variable "grafana_ha_vlan_id" {
  description = "HA VLAN of the Grafana VMs (L2VNI ha_grafana): unified alerting's gossip (9094) and keepalived's unicast adverts. Every Grafana VM needs one addressed NIC on it, or gossip stays on the backend and keepalived is skipped."
  type        = number
  default     = 213
}

variable "grafana_vrrp" {
  description = "Grafana keepalived VIP (CIDR on the UI NIC, the one with the default gateway) and VRRP router id. The PASS password is generated. null = no keepalived/VIP."
  type = object({
    vip       = string
    router_id = optional(number, 11)
  })
  default = {
    vip = "10.2.11.40/16"
  }
}

variable "monitoring_bridge" {
  description = "Bridge of the monitoring network NIC on the role = \"monitoring\" VM (UIs, PVE metric pushes, node_exporter)."
  type        = string
  default     = "vmbr100"
}

variable "pve_monitoring_bridge" {
  description = "pve_network.bridges key whose cidrhost_prefix gives each Proxmox node's monitoring address (cidrhost(prefix, id))."
  type        = string
  default     = "100"
}

variable "images" {
  description = "Container images. Pin exact tags (or digests) for reproducible deployments."
  type = object({
    prometheus        = optional(string, "docker.io/prom/prometheus:v3.15.1")
    alertmanager      = optional(string, "docker.io/prom/alertmanager:v0.34.1")
    node_exporter     = optional(string, "docker.io/prom/node-exporter:v1.12.1")
    snmp_exporter     = optional(string, "docker.io/prom/snmp-exporter:v0.30.1")
    blackbox_exporter = optional(string, "docker.io/prom/blackbox-exporter:v0.29.1")
    pve_exporter      = optional(string, "docker.io/prompve/prometheus-pve-exporter:3.10.2")
    influxdb          = optional(string, "docker.io/library/influxdb:2.8")
    postgres          = optional(string, "docker.io/library/postgres:17")
    grafana           = optional(string, "docker.io/grafana/grafana:13.2.5")
    loki              = optional(string, "docker.io/grafana/loki:3.7.9")
    alloy             = optional(string, "docker.io/grafana/alloy:v1.21.3")
    haproxy           = optional(string, "docker.io/library/haproxy:3.2.26") # LTS branch
  })
  default = {}
}

variable "settings" {
  description = "Retention, Grafana root URL, InfluxDB org/bucket and the DNS probe zone. See modules/services/monitoring."
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

variable "pve_exporter_token" {
  description = "Read-only PVE API token for pve-exporter (see README). null leaves pve-exporter out. Put it in a *.secret.auto.tfvars file."
  sensitive   = true
  type = object({
    user       = string
    token_name = string
    value      = string
  })
  default = null
}

variable "vyos_extra_targets" {
  description = "VyOS routers outside the inventory: host => management IP. Scraped for node (:9100) and FRR (:9342) exporters."
  type        = map(string)
  default     = { "fw-wan" = "10.20.10.255" }
}

variable "ceph_mgr_nodes" {
  description = "Proxmox nodes running a Ceph mgr. Prometheus scrapes the mgr prometheus module (:9283) on each one's monitoring address; only the active mgr returns metrics. Empty leaves the ceph job out."
  type        = list(string)
  default     = ["macbeth", "titania", "venom", "zoness"]
}

variable "vyos_telegraf_targets" {
  description = "VyOS routers running telegraf's prometheus-client output (service monitoring telegraf prometheus-client): host => address (port 9273). It carries the per-rule firewall counters VyOS only collects with the influxdb output configured."
  type        = map(string)
  default     = { "fw-wan" = "10.5.0.255" }
}

variable "node_extra_targets" {
  description = "Other Linux hosts running node_exporter: host => IP (port 9100)."
  type        = map(string)
  default     = {}
}

variable "snmp_targets" {
  description = "SNMP jobs: job suffix => modules (from the exporter's bundled snmp.yml), auth and host => IP. Use the devices' monitoring-network (10.5/16) addresses: the MikroTiks bind their SNMP agent there."
  type = map(object({
    modules = list(string)
    auth    = optional(string, "public_v2")
    targets = map(string)
  }))
  default = {
    fs-switches = {
      modules = ["if_mib", "system"]
      targets = { "switch-1" = "10.5.0.1", "switch-2" = "10.5.0.2" }
    }
    mikrotik-access = {
      modules = ["if_mib", "mikrotik", "system"]
      targets = { "m317-1" = "10.5.0.4", "m317-2" = "10.5.0.3" }
    }
    spines = {
      modules = ["if_mib", "mikrotik", "system"]
      targets = { "m326-1" = "10.5.0.5", "m326-2" = "10.5.0.6" }
    }
    wlc = {
      # IOS-XE secure mode refuses v1/v2c, so the WLCs use SNMPv3 (snmp_v3_auths "lylat_v3").
      # The bundled cisco_wlc module (AireOS MIBs) emits duplicate series on the C9800
      # (several WLANs report an empty SSID), which fails the whole scrape, so it's left out.
      modules = ["if_mib", "system"]
      auth    = "lylat_v3"
      targets = { "c9800-wlc-1" = "10.5.1.1", "c9800-wlc-2" = "10.5.1.2" }
    }
  }
}

variable "blackbox_icmp_targets" {
  description = "host => IP for ICMP reachability probes."
  type        = map(string)
  default = {
    "fw-wan" = "10.20.10.255"
    netbox   = "10.2.0.40"
    v100     = "10.12.0.10"
  }
}

variable "blackbox_http_targets" {
  description = "host => URL for HTTP 2xx probes."
  type        = map(string)
  default = {
    netbox       = "http://10.2.0.40:8000/login/"
    "llama-v100" = "http://10.12.0.10:8080/health"
  }
}

variable "grafana_admin_password" {
  description = "Grafana 'admin' password. null generates one (output grafana_admin_password). Only applied when Grafana first creates the admin user."
  type        = string
  sensitive   = true
  default     = null
}

variable "influxdb_admin_password" {
  description = "InfluxDB 'admin' password (at least 8 characters). null generates one. Only applied when InfluxDB first initialises."
  type        = string
  sensitive   = true
  default     = null
  validation {
    condition     = var.influxdb_admin_password == null || length(coalesce(var.influxdb_admin_password, "xxxxxxxx")) >= 8
    error_message = "InfluxDB requires a password of at least 8 characters."
  }
}

variable "snmp_v3_auths" {
  description = "SNMPv3 auths for snmp_exporter: name => { username, password, priv_password, ... } (see modules/services/monitoring). Reference the name as an snmp_targets auth. Put it in a git-ignored *.secret.auto.tfvars."
  type = map(object({
    username       = string
    security_level = optional(string, "authPriv")
    auth_protocol  = optional(string, "SHA")
    password       = string
    priv_protocol  = optional(string, "AES")
    priv_password  = string
  }))
  sensitive = true
  default   = {}
}

variable "pve_api_token" {
  description = "Proxmox cluster API token (proxmox.secret.auto.tfvars, linked from inventory/auto.tfvars.secret/). Used for the cluster's metric server."
  type        = string
  sensitive   = true
}

variable "greatfox_api_token" {
  description = "API token of the standalone Proxmox host (proxmox.secret.auto.tfvars). Used for its metric server."
  type        = string
  sensitive   = true
}

variable "pve_api_node" {
  description = "Cluster node whose API manages the cluster-wide metric server. null uses nodes.cluster_api_node; set another node when that one is unreachable."
  type        = string
  default     = null
}

variable "pve_metrics" {
  description = "Proxmox external metric servers (pvestatd, every ~10 s) writing to InfluxDB on mon01 over HTTP: one bucket and one write-only token for the cluster (\"<cluster_bucket>\") and one per standalone host (\"<standalone_bucket_prefix><host>\")."
  type = object({
    enabled                  = optional(bool, true) # false keeps the config but stops pvestatd sending
    cluster_bucket           = optional(string, "pve_cluster")
    standalone_bucket_prefix = optional(string, "pve_")
    retention_days           = optional(number, 90)
  })
  default = {}
}

variable "vyos_telegraf_bucket" {
  description = "InfluxDB bucket that Telegraf on the VyOS routers (fw-wan) writes to. Same retention as pve_metrics."
  type        = string
  default     = "vyos"
}

variable "logging_settings" {
  description = "Logging (role = \"logging\" VMs): VIPs, VRRP router id, Ceph RGW endpoints behind each VM's haproxy, Loki retention/replication, schema start date, sources allowed to reach Loki. See modules/services/monitoring."
  type = object({
    vips = optional(object({
      backend    = optional(string, "10.13.11.40/16")
      monitoring = optional(string, "10.5.11.40/16")
      mgmt       = optional(string, "10.20.11.40/16")
    }), {})
    vrrp_router_id        = optional(number, 40)
    rgw_endpoints         = optional(list(string), ["10.27.0.12:7480", "10.27.0.13:7480", "10.27.0.17:7480"]) # macbeth, titania, venom
    retention_period      = optional(string, "90d")
    replication_factor    = optional(number, 3)
    schema_start          = optional(string, "2026-11-01")
    loki_allowed_sources  = optional(list(string), ["10.13.0.0/16"])
    syslog_host_overrides = optional(map(string), {}) # sender IP => host label, on top of the snmp_targets addresses
  })
  default = {}
}

variable "loki_s3" {
  description = "Loki's S3 bucket and the RGW user's keys (logging.secret.auto.tfvars, git-ignored). Required when there are logging VMs."
  type = object({
    bucket     = string
    access_key = string
    secret_key = string
  })
  sensitive = true
  default   = null
}
