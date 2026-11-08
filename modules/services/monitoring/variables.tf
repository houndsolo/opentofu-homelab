variable "backend" {
  description = "The one monitoring backend VM (Prometheus, Alertmanager, exporters, InfluxDB, Postgres)."
  type = object({
    name               = string
    monitoring_address = string # Monitoring network (10.5/16): UIs, PVE metric pushes, node_exporter.
    backend_address    = string # Isolated backend VLAN (10.13/16): Grafana -> datasources and Postgres.
  })
}

variable "grafana" {
  description = "Grafana front ends, keyed by VM name. backend_address is the VM's address on the backend VLAN."
  type = map(object({
    backend_address = string
  }))
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

variable "settings" {
  description = "Retention, external URLs and InfluxDB naming."
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
