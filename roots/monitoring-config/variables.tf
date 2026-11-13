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
    router_id = optional(number, 100)
  })
  default = {
    vip = "10.2.11.100/16"
  }
}

variable "monitoring_primary" {
  description = "The role = \"monitoring\" VM that runs Postgres (Grafana's database) and that the default influxdb provider talks to. The other one (at most one more) is the replica."
  type        = string
  default     = "mon01"
}

variable "monitoring_ha_vlan_id" {
  description = "HA VLAN of the monitoring backends (L2VNI ha_monitor): keepalived's unicast adverts and Alertmanager gossip (9094). Every backend needs one addressed NIC on it, or gossip stays on the backend VLAN and keepalived is skipped."
  type        = number
  default     = 215
}

variable "backend_vrrp" {
  description = "keepalived on the backends: VIPs (CIDR) on the monitoring network (InfluxDB) and the backend VLAN (Grafana's InfluxDB/Alertmanager datasources), VRRP router id. The PASS password is generated. null = no keepalived; datasources stay on the primary."
  type = object({
    vips = optional(object({
      monitoring = optional(string, "10.5.11.102/16")
      backend    = optional(string, "10.13.11.102/16")
    }), {})
    router_id = optional(number, 102)
  })
  default = {}
}

variable "influxdb_replica_ready" {
  description = "true once the replica backend (mon02) is deployed and its InfluxDB answers: creates its buckets and write tokens (provider influxdb.replica), its Proxmox metric servers, and turns on its WLC Telegraf. The provider can't plan against an InfluxDB that isn't running yet."
  type        = bool
  default     = false
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
    telegraf          = optional(string, "docker.io/library/telegraf:1.40.3")
    mimir             = optional(string, "docker.io/grafana/mimir:3.2.4") # classic architecture (no Kafka)
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
    grafana_root_url          = optional(string, "https://grafana.lylat.space/") # through the reverse proxy (services-config proxy.tf)
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
    # null = Prometheus's global 30s interval / 10s timeout. The timeout must not exceed the interval.
    scrape_interval = optional(string)
    scrape_timeout  = optional(string)
  }))
  default = {
    fs-switches = {
      modules = ["if_mib", "system"]
      targets = { "switch-1" = "10.5.0.1", "switch-2" = "10.5.0.2" }
    }
    mikrotik-access = {
      # mikrotik_lite: only what the dashboards use, not the whole MIKROTIK-MIB (DT-023).
      modules = ["if_mib", "mikrotik_lite", "system"]
      # Not a typo: the vlan5 addresses are crossed vs mgmt (m317-1 = 10.20.0.3 / 10.5.0.4), per the devices and NetBox.
      targets = { "m317-1" = "10.5.0.4", "m317-2" = "10.5.0.3" }
      # RouterOS walks are slow (the bundled mikrotik module took 5-17 s); two Prometheus poll them.
      # mikrotik_lite walks ~half the PDUs (median 5.5 s); the 30s/20s headroom stays for now.
      scrape_interval = "30s"
      scrape_timeout  = "20s"
    }
    spines = {
      modules         = ["if_mib", "mikrotik_lite", "system"]
      targets         = { "m326-1" = "10.5.0.5", "m326-2" = "10.5.0.6" }
      scrape_interval = "30s"
      scrape_timeout  = "20s"
    }
    # HOST-RESOURCES-MIB (CPU load, memory and system disk use, device status, clock) for the
    # mikrotik-snmp dashboard, as its own job: these walks take 0.01-0.5 s, while the jobs
    # above already need 7-15 s (p95) and sometimes hit their 20 s timeout, which would drop
    # these series with everything else.
    mikrotik-hr = {
      modules = ["hrDevice", "hrStorage", "hrSystem"]
      targets = { "m317-1" = "10.5.0.4", "m317-2" = "10.5.0.3", "m326-1" = "10.5.0.5", "m326-2" = "10.5.0.6" }
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
    netbox   = "10.2.11.106" # NetBox VIP
    v100     = "10.12.0.10"
  }
}

variable "blackbox_https_targets" {
  description = "host => https URL for probes of the sites published through the nginx reverse proxy (job blackbox-https: status, TLS, cert expiry). Keep in step with services-config var.proxy.hosts."
  type        = map(string)
  default = {
    grafana     = "https://grafana.lylat.space/api/health"
    netbox      = "https://netbox.lylat.space/login/"
    dark-triage = "https://dark-triage.lylat.space/api/health"
    proxy       = "https://proxy.lylat.space/" # the proxy's landing page
  }
}

variable "blackbox_http_targets" {
  description = "host => URL for HTTP 2xx probes."
  type        = map(string)
  default = {
    netbox       = "http://10.2.11.106/login/" # NetBox VIP (netbox01/02)
    "llama-v100" = "http://10.12.0.10:8080/health"
    dark-triage  = "http://10.2.11.105/api/health" # the VIP; 200 only when the app reaches its database
    triage01     = "http://10.2.11.43/api/health"
    triage02     = "http://10.2.11.44/api/health"
    netbox01     = "http://10.2.11.45/login/" # NetBox HA pair (services-config netbox.tf)
    netbox02     = "http://10.2.11.46/login/"
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

variable "wlc_telemetry" {
  description = "C9800 model-driven telemetry: the WLCs dial out over gRPC to Telegraf on mon01 (monitoring-network address, port), which writes to InfluxDB bucket `bucket` with its own write-only token (same retention as pve_metrics). null leaves Telegraf, the bucket and the token out. The WLC side is configured by hand (see the README)."
  type = object({
    port   = optional(number, 57500)
    bucket = optional(string, "wlc")
  })
  default = {}
}

variable "logging_settings" {
  description = "Logging (role = \"logging\" VMs): VIPs, VRRP router id, Ceph RGW endpoints behind each VM's haproxy, Loki retention/replication, schema start date, sources allowed to reach Loki. See modules/services/monitoring."
  type = object({
    vips = optional(object({
      backend    = optional(string, "10.13.11.101/16")
      monitoring = optional(string, "10.5.11.101/16")
      # No mgmt VIP: syslog senders on the management network use each logging VM's own address.
    }), {})
    vrrp_router_id        = optional(number, 101)
    rgw_endpoints         = optional(list(string), ["10.27.0.12:7480", "10.27.0.13:7480", "10.27.0.17:7480"]) # macbeth, titania, venom
    retention_period      = optional(string, "90d")
    replication_factor    = optional(number, 3)
    schema_start          = optional(string, "2026-11-01")
    loki_allowed_sources  = optional(list(string), ["10.13.0.0/16"])
    syslog_host_overrides = optional(map(string), {})                         # sender IP => host label, on top of the snmp_targets addresses
    syslog_dedup_hosts    = optional(string, "LEAF-[0-9]+|fw-wan|dhcp0[0-9]") # VyOS senders: drop the imuxsock copy of each line
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

variable "metrics_ha_vlan_id" {
  description = "HA VLAN of the Mimir VMs (L2VNI ha_mimir): memberlist, gRPC and keepalived's unicast adverts. Each metrics VM needs one addressed NIC on it."
  type        = number
  default     = 216
}

variable "metrics_settings" {
  description = "Mimir (role = \"metrics\" VMs): VIP, VRRP router id, RGW endpoints, replication, retention, HA tracker labels, limits. See modules/services/monitoring (variable metrics_settings)."
  type = object({
    vip                        = optional(string, "10.13.11.103/16")
    vrrp_router_id             = optional(number, 103)
    rgw_endpoints              = optional(list(string), ["10.27.0.12:7480", "10.27.0.13:7480", "10.27.0.17:7480"]) # macbeth, titania, venom
    replication_factor         = optional(number, 3)
    retention_period           = optional(string, "396d")
    ha_cluster_label           = optional(string, "ha_cluster")
    ha_replica_label           = optional(string, "__replica__")
    drop_labels                = optional(list(string), ["ha_cluster", "site"])
    max_series                 = optional(number, 300000)
    ingestion_rate             = optional(number, 300000)  # each of the 3 distributors allows a third; the VIP sends everything to one
    ingestion_burst_size       = optional(number, 2000000) # per distributor
    max_label_names_per_series = optional(number, 40)
    out_of_order_time_window   = optional(string, "10m")
    block_upload_enabled       = optional(bool, true)
    allowed_sources            = optional(list(string), ["10.13.0.0/16"])
  })
  default = {}
}

variable "mimir_s3" {
  description = "Mimir's S3 bucket and the RGW user's keys (metrics.secret.auto.tfvars, git-ignored). null leaves Mimir out (see check mimir_s3)."
  type = object({
    bucket     = string
    access_key = string
    secret_key = string
  })
  sensitive = true
  default   = null
}

variable "postgres_ha_vlan_id" {
  description = "HA VLAN of the Patroni members (L2VNI ha_postgres): streaming replication, etcd, Patroni REST and keepalived's unicast adverts. Each postgres VM needs one addressed NIC on it."
  type        = number
  default     = 217
}

variable "postgres_settings" {
  description = "Patroni cluster (role = \"postgres\" VMs): VIP, VRRP router id, cluster name, PostgreSQL major (pg_major, PGDG), RGW endpoints, backup schedule/retention, Postgres parameters, Grafana cutover switches (grafana_on_cluster, legacy_on_primary), accepted Debian package series. See modules/services/monitoring (variable postgres_settings)."
  type = object({
    vip                        = optional(string, "10.13.11.104/16")
    vrrp_router_id             = optional(number, 104)
    cluster_name               = optional(string, "lylat-pg")                                                      # etcd; Patroni scope/stanza = cluster_name + pg_major
    pg_major                   = optional(number, 18)                                                              # PGDG; a new major is a rebuild + dump/restore (new scope/stanza/data dir)
    rgw_endpoints              = optional(list(string), ["10.27.0.12:7480", "10.27.0.13:7480", "10.27.0.17:7480"]) # macbeth, titania, venom
    retention_days             = optional(number, 14)
    backup_schedule            = optional(string, "*-*-* 01:30:00")
    archive_timeout            = optional(number, 300)
    maximum_lag_on_failover    = optional(number, 1048576)
    max_connections            = optional(number, 200)
    parameters                 = optional(map(string), {})
    etcd_initial_cluster_state = optional(string, "new")
    etcd_heartbeat_interval    = optional(number, 300)  # ms; slow Ceph RBD fsync (DT-017)
    etcd_election_timeout      = optional(number, 3000) # ms; ~10x the heartbeat
    grafana_on_cluster         = optional(bool, false)  # step 5 of runbook-postgres.md
    legacy_on_primary          = optional(bool, true)   # step 7 (later): false removes mon01's Postgres container
    bootstrap_from_backup      = optional(bool, false)  # disaster recovery: bootstrap a fresh cluster from pgBackRest (README)
    restore_target_time        = optional(string)       # with bootstrap_from_backup: PITR target, e.g. "2026-11-20 12:00:00+00"
    package_versions = optional(map(string), {          # + postgresql-<pg_major> = "<pg_major>.*" (module)
      "patroni"     = "4.1.*"
      "etcd-server" = "3.5.*"
      "pgbackrest"  = "2.60.*"
    })
  })
  default = {}
  validation {
    condition     = floor(var.postgres_settings.pg_major) == var.postgres_settings.pg_major && var.postgres_settings.pg_major >= 17
    error_message = "postgres_settings.pg_major is a PostgreSQL major version (an integer, 17 or later)."
  }
}

variable "postgres_s3" {
  description = "pgBackRest's S3 bucket and the RGW user's keys (postgres.secret.auto.tfvars, git-ignored). null leaves the Patroni cluster out (see check postgres_s3)."
  type = object({
    bucket     = string
    access_key = string
    secret_key = string
  })
  sensitive = true
  default   = null
}

variable "rgw_bucket_alerts" {
  description = "Thresholds of the per-bucket Ceph RGW alerts (module rgw.tf; the metrics come from pve-collectors/rgw-bucket-stats.py on the RGW nodes): growth_1h_bytes, growth_24h_bytes, quota_ratio, quota_horizon_days, stats_max_age_seconds. Unset keys keep the module's defaults."
  type = object({
    growth_1h_bytes       = optional(number)
    growth_24h_bytes      = optional(number)
    quota_ratio           = optional(number)
    quota_horizon_days    = optional(number)
    stats_max_age_seconds = optional(number)
  })
  default = {}
  validation {
    condition     = (var.rgw_bucket_alerts.quota_ratio == null || (coalesce(var.rgw_bucket_alerts.quota_ratio, 1) > 0 && coalesce(var.rgw_bucket_alerts.quota_ratio, 1) <= 1)) && coalesce(var.rgw_bucket_alerts.quota_horizon_days, 1) > 0
    error_message = "rgw_bucket_alerts.quota_ratio must be in (0, 1] and quota_horizon_days positive."
  }
}

variable "app_db_passwords" {
  description = "Postgres passwords of application databases on the Patroni cluster (git-ignored app-db.secret.auto.tfvars, shared with services-config). An app gets its role/database only when it has a password here and VMs to connect from."
  sensitive   = true
  type        = map(string)
  default     = {}
}
