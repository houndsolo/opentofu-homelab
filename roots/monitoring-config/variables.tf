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
  })
  default = {}
}

variable "settings" {
  description = "Retention, Grafana root URL, InfluxDB org/bucket and the DNS probe zone. See modules/services/monitoring."
  type = object({
    prometheus_retention_time = optional(string, "90d")
    prometheus_retention_size = optional(string, "120GB")
    influxdb_org              = optional(string, "lylat")
    influxdb_bucket           = optional(string, "proxmox")
    influxdb_retention        = optional(string, "90d")
    grafana_root_url          = optional(string, "http://grafana.lylat.space:3000/")
    dns_probe_zone            = optional(string, "lylat.space")
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
      modules = ["if_mib", "mikrotik"]
      targets = { "m317-1" = "10.5.0.4", "m317-2" = "10.5.0.3" }
    }
    spines = {
      modules = ["if_mib", "mikrotik"]
      targets = { "m326-1" = "10.5.0.5", "m326-2" = "10.5.0.6" }
    }
    wlc = {
      modules = ["if_mib", "cisco_wlc"]
      targets = { "c9800-wlc-1" = "10.20.1.1", "c9800-wlc-2" = "10.20.1.2" }
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
