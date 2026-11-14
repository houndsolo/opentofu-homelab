variable "backends" {
  description = "Monitoring backend VMs (Prometheus, Alertmanager, exporters, Telegraf), keyed by VM name. Each runs the same scrape config (a Prometheus HA pair, deduplicated by Mimir's HA tracker) and the Alertmanagers form one cluster. primary_backend also runs Postgres (Grafana's database). ha_address/interfaces: the HA VLAN (keepalived adverts, Alertmanager gossip) and NIC names for backend_vrrp."
  type = map(object({
    monitoring_address = string           # Monitoring network (10.5/16): UIs, PVE metric pushes, node_exporter, WLC telemetry.
    backend_address    = string           # Zone NIC (lylat-app/-obs/-data, DT-090): Grafana -> datasources and Postgres.
    telemetry_address  = optional(string) # lylat-telemetry (VLAN 1501): node_exporter, Alloy and other exporters listen here; null = the old address
    ha_address         = optional(string) # HA VLAN (ha_monitor): null on any VM keeps gossip on the backend VLAN and keepalived off
    interfaces = optional(object({
      ha         = string
      backend    = string
      monitoring = string
    }))
  }))
  validation {
    condition     = length(var.backends) > 0
    error_message = "Define at least one backend."
  }
}

variable "primary_backend" {
  description = "The backend VM that runs Postgres (Grafana's shared database, a single instance) and whose Prometheus Grafana falls back to without Mimir."
  type        = string
  validation {
    condition     = length(var.primary_backend) > 0
    error_message = "Name the primary backend."
  }
}

variable "backend_vrrp" {
  description = "keepalived on the backends: VIPs (CIDR) on the monitoring network (the C9800s' telemetry receiver) and the backend VLAN (Grafana's Alertmanager datasource, the wlc scrape), VRRP router id. Needs ha_address/interfaces on every backend and at least two. null = no keepalived, datasources on the primary."
  type = object({
    vips = object({
      monitoring = string
      backend    = string
    })
    router_id = optional(number, 102)
  })
  default = null
  validation {
    condition     = var.backend_vrrp == null || try(can(cidrhost(var.backend_vrrp.vips.monitoring, 0)) && can(cidrhost(var.backend_vrrp.vips.backend, 0)) && var.backend_vrrp.router_id >= 1 && var.backend_vrrp.router_id <= 255, false)
    error_message = "backend_vrrp needs vips.monitoring/backend as IPv4 CIDRs, router_id 1..255."
  }
}

variable "grafana" {
  description = "Grafana front ends, keyed by VM name. backend_address is the VM's address on the backend VLAN; ha_address on the Grafana HA VLAN (alerting gossip, VRRP), and interfaces the VM's NIC names for VRRP (ha, and vip: the UI NIC that holds grafana_vrrp.vip)."
  type = map(object({
    backend_address   = string
    telemetry_address = optional(string) # lylat-telemetry (VLAN 1501): node_exporter, Alloy and other exporters listen here; null = the old address
    ha_address        = optional(string) # null on any VM: gossip stays on the backend and no keepalived
    interfaces = optional(object({
      ha  = string
      vip = string
    }))
  }))
}

variable "grafana_vrrp" {
  description = "keepalived VIP for Grafana (CIDR on the UI NIC), VRRP router id. Needs ha_address/interfaces on every Grafana VM and at least two VMs. null = no keepalived."
  type = object({
    vip       = string
    router_id = optional(number, 100)
  })
  default = null
  validation {
    condition     = var.grafana_vrrp == null || try(can(cidrhost(var.grafana_vrrp.vip, 0)) && var.grafana_vrrp.router_id >= 1 && var.grafana_vrrp.router_id <= 255, false)
    error_message = "grafana_vrrp needs vip as an IPv4 CIDR, router_id 1..255."
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
    postgres          = string
    grafana           = string
    loki              = string
    alloy             = string
    haproxy           = string
    telegraf          = string
    mimir             = optional(string, "docker.io/grafana/mimir:3.2.4")
    postgres_exporter = optional(string, "quay.io/prometheuscommunity/postgres-exporter:v0.20.1")
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
    valkey   = optional(list(object({ host = string, address = string })), [])                       # Valkey (:9121) and Sentinel (:9355) redis_exporters
    netbox   = optional(list(object({ host = string, address = string })), [])                       # NetBox /metrics on each node's service address, :80
    nginx    = optional(list(object({ host = string, address = string })), [])                       # nginx-prometheus-exporter on the proxy VMs' mgmt address, :9113
    bind     = optional(list(object({ host = string, address = string })), [])                       # bind_exporter on the DNS VMs' mgmt address, :9119
    alloy    = optional(list(object({ host = string, address = string })), [])                       # Alloy on VMs deployed elsewhere (services-config alloy.tf), mgmt address :12345
    snmp = map(object({                                                                              # job suffix => host => IP
      modules         = list(string)
      auth            = string
      targets         = map(string)
      scrape_interval = optional(string) # null: the global 30s
      scrape_timeout  = optional(string) # null: the global 10s
    }))
    blackbox = map(list(object({ host = string, target = string }))) # blackbox module => targets (IP or URL)
  })
}

variable "secrets" {
  description = "Generated credentials. Postgres reads its password only when its data directory is first initialised."
  sensitive   = true
  type = object({
    grafana_db_password    = string
    grafana_admin_password = string
    grafana_secret_key     = string
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
  description = "Retention, external URLs and Ceph labels."
  type = object({
    prometheus_retention_time = optional(string, "7d")
    prometheus_retention_size = optional(string, "20GB")
    grafana_root_url          = optional(string, "https://grafana.lylat.space/") # through the reverse proxy (services-config proxy.tf)
    dns_probe_zone            = optional(string, "lylat.space")
    ceph_cluster_name         = optional(string, "lylat") # cluster label on ceph metrics (ceph-mixin dashboards filter on it)
    # Label matchers added to the ceph-mixin's node_* alerts (main.tf), which assume node_exporter
    # runs on the Ceph nodes only. null: host=~ the PVE cluster's nodes (targets.pve; standalone
    # PVE hosts aren't in Ceph); "": the upstream rules unchanged.
    ceph_node_selector = optional(string)
  })
  default = {}
}

variable "logging" {
  description = "Logging VMs (Loki ring, Alloy syslog receiver, haproxy to the RGWs, keepalived), keyed by VM name. Name order sets the VRRP priority (150, 100, 50). Empty leaves logging out; Alloy (journal) still runs on the backend and Grafana VMs."
  type = map(object({
    backend_address    = string           # backend VLAN: Loki HTTP API (Grafana, Alloy pushes), scrapes
    telemetry_address  = optional(string) # lylat-telemetry (VLAN 1501): node_exporter, Alloy and other exporters listen here; null = the old address
    ha_address         = string           # HA VLAN: Loki ring (memberlist, ingester gRPC) and VRRP adverts
    monitoring_address = string           # monitoring network: syslog from devices and PVE nodes
    interfaces = object({                 # the VM's interface name on each of those networks (VRRP)
      ha         = string
      backend    = string
      monitoring = string
      telemetry  = optional(string) # holds the Loki push VIP (logging_settings.vips.telemetry)
    })
  }))
  default = {}
}

variable "logging_settings" {
  description = "VIPs (CIDR, one per client network, all in one VRRP instance), VRRP router id, the Ceph RGW endpoints behind each VM's haproxy, Loki retention and replication, the schema's start date, which sources may reach Loki's ports and the syslog host overrides and VyOS dedup."
  type = object({
    vips = optional(object({
      backend    = optional(string, "10.54.18.101/16") # Grafana datasource, Alloy pushes from the other VMs
      monitoring = optional(string, "10.5.11.101/16")  # syslog from devices and PVE nodes
      telemetry  = optional(string)                    # Alloy pushes from every VM (lylat-telemetry); null = none
      # No VIP on the management network: the VyOS leaves, DHCP and DNS VMs send syslog to
      # every logging VM's own mgmt address (Loki drops the identical copies).
    }), {})
    vrrp_router_id        = optional(number, 101)
    rgw_endpoints         = optional(list(string), ["10.27.0.12:7480", "10.27.0.13:7480", "10.27.0.17:7480"])
    retention_period      = optional(string, "90d")
    replication_factor    = optional(number, 3)
    schema_start          = optional(string, "2026-11-01")                                           # never change once Loki has data; add a new period instead
    loki_allowed_sources  = optional(list(string), ["10.52.0.0/16", "10.54.0.0/16", "10.55.0.0/16"]) # Loki HTTP (3100); the ring ports only accept the logging VMs
    syslog_host_overrides = optional(map(string), {})                                                # sender IP => host label
    # Host label regex (anchored) of the VyOS senders: their rsyslog sends each non-kernel line twice and
    # the receiver drops the copy with one leading space (templates/config.alloy.tftpl). "" turns it off.
    syslog_dedup_hosts = optional(string, "LEAF-[0-9]+|fw-wan|dhcp0[0-9]")
  })
  default = {}
  validation {
    condition     = length(var.logging_settings.rgw_endpoints) > 0 && alltrue([for e in var.logging_settings.rgw_endpoints : can(regex("^[0-9.]+:[0-9]+$", e))])
    error_message = "rgw_endpoints are \"IP:port\" strings, at least one."
  }
}

variable "logging_secrets" {
  description = "Loki's S3 bucket and keys (RGW user). Required when logging is non-empty."
  sensitive   = true
  type = object({
    s3_bucket     = string
    s3_access_key = string
    s3_secret_key = string
  })
  default = null
}

variable "pvestatd" {
  description = "Telegraf on every backend accepting the Proxmox nodes' pvestatd metric server writes (InfluxDB v2 line protocol) on monitoring_address:port and serving them to Prometheus (job pvestatd, pvestatd.tf). The token is pvestatd_token. null leaves it out."
  type = object({
    port = optional(number, 8186)
  })
  default = null
  validation {
    condition     = var.pvestatd == null || try(var.pvestatd.port >= 1024 && var.pvestatd.port <= 65535 && !contains([9273, 9274, 9275], var.pvestatd.port), false)
    error_message = "pvestatd.port must be an unprivileged port (1024..65535) other than Telegraf's metrics ports 9273/9274/9275."
  }
}

variable "pvestatd_token" {
  description = "Token the PVE metric servers send to the pvestatd Telegraf (any random string; the root generates it)."
  type        = string
  sensitive   = true
  default     = null
}

variable "wlc_telemetry" {
  description = "Telegraf on the backends in `backends` receiving Cisco model-driven telemetry (gRPC dial-out, kvGPB) from the C9800 WLCs on their monitoring_address:port (and the monitoring VIP), served to Prometheus as wlc_* (job wlc). null leaves Telegraf out."
  type = object({
    port     = optional(number, 57500)
    backends = list(string)
  })
  default = null
  validation {
    condition     = var.wlc_telemetry == null || try(var.wlc_telemetry.port >= 1024 && var.wlc_telemetry.port <= 65535 && var.wlc_telemetry.port != 9273, false)
    error_message = "wlc_telemetry.port must be an unprivileged port (1024..65535) other than 9273 (Telegraf's metrics)."
  }
}

variable "metrics" {
  description = "Mimir VMs (role = \"metrics\": Mimir ring, haproxy to the RGWs, keepalived, Alloy, node_exporter), keyed by VM name. Name order sets the VRRP priority (150, 100, 50). Empty, or metrics_secrets = null, leaves Mimir out: Prometheus then has no remote_write and Grafana queries Prometheus directly."
  type = map(object({
    backend_address   = string           # backend VLAN: Mimir HTTP (push, queries), scrapes; holds the VIP
    telemetry_address = optional(string) # lylat-telemetry (VLAN 1501): node_exporter, Alloy and other exporters listen here; null = the old address
    ha_address        = string           # Mimir HA VLAN: memberlist, gRPC, VRRP adverts
    interfaces = object({                # NIC names for VRRP
      ha      = string
      backend = string
    })
  }))
  default = {}
}

variable "metrics_settings" {
  description = "Mimir: VIP (CIDR on the backend VLAN NIC), VRRP router id, the RGWs behind each VM's haproxy, replication, retention, HA tracker labels and per-tenant limits, and which sources may reach Mimir's HTTP port."
  type = object({
    vip                        = optional(string, "10.54.17.103/16")
    vrrp_router_id             = optional(number, 103)
    rgw_endpoints              = optional(list(string), ["10.27.0.12:7480", "10.27.0.13:7480", "10.27.0.17:7480"])
    replication_factor         = optional(number, 3)
    retention_period           = optional(string, "396d") # ~13 months (compactor deletes older blocks)
    ha_cluster_label           = optional(string, "ha_cluster")
    ha_replica_label           = optional(string, "__replica__")
    drop_labels                = optional(list(string), ["ha_cluster", "site"]) # after HA dedup: the Prometheus external labels
    max_series                 = optional(number, 300000)                       # ~118k active today (default 150k)
    ingestion_rate             = optional(number, 300000)                       # samples/s, per tenant, split over the healthy distributors (see below)
    ingestion_burst_size       = optional(number, 2000000)                      # per distributor (not split)
    max_label_names_per_series = optional(number, 40)                           # 21 at most today (default 30)
    out_of_order_time_window   = optional(string, "10m")
    block_upload_enabled       = optional(bool, false) # true only while running a mimirtool backfill (mon-ha/mimir-runbook.md step 3)
    allowed_sources            = optional(list(string), ["10.54.0.0/16", "10.52.0.0/16"])
  })
  default = {}
  validation {
    condition     = can(cidrhost(var.metrics_settings.vip, 0)) && length(var.metrics_settings.rgw_endpoints) > 0 && alltrue([for e in var.metrics_settings.rgw_endpoints : can(regex("^[0-9.]+:[0-9]+$", e))])
    error_message = "metrics_settings.vip is an IPv4 CIDR and rgw_endpoints are \"IP:port\" strings, at least one."
  }
}

variable "metrics_secrets" {
  description = "Mimir's S3 bucket and keys (RGW user). null leaves Mimir out."
  sensitive   = true
  type = object({
    s3_bucket     = string
    s3_access_key = string
    s3_secret_key = string
  })
  default = null
}

variable "postgres" {
  description = "Patroni members (role = \"postgres\": PostgreSQL (postgres_settings.pg_major, PGDG), Patroni, etcd, pgBackRest, keepalived, haproxy to the RGWs, exporters, Alloy), keyed by VM name. Name order sets the VRRP priority (first election only). Empty, or postgres_secrets = null, leaves the cluster out (Grafana stays on the primary backend's Postgres)."
  type = map(object({
    backend_address   = string           # backend VLAN: Grafana -> the VIP, scrapes; holds the VIP
    telemetry_address = optional(string) # lylat-telemetry (VLAN 1501): node_exporter, Alloy and other exporters listen here; null = the old address
    ha_address        = string           # Postgres HA VLAN: replication, etcd, Patroni REST, VRRP adverts
    interfaces = object({                # NIC names for VRRP
      ha      = string
      backend = string
    })
  }))
  default = {}
}

variable "postgres_settings" {
  description = "Patroni cluster: VIP (CIDR on the backend NIC), VRRP router id, cluster name (etcd data dir/token; with pg_major the Patroni scope and pgBackRest stanza, e.g. lylat-pg18), PostgreSQL major (PGDG packages), RGWs behind each member's haproxy, backup schedule/retention, Postgres parameters, the Grafana cutover switches and the package series the deploy accepts."
  type = object({
    vip            = optional(string, "10.56.14.104/16")
    vrrp_router_id = optional(number, 104)
    cluster_name   = optional(string, "lylat-pg")
    # PostgreSQL major version, from the PGDG repository (Debian 13 has 17 only). Changing it is a
    # rebuild, not an in-place upgrade: the new major gets its own Patroni scope and pgBackRest
    # stanza ("<cluster_name><pg_major>") and data dir, so the old cluster's are left untouched
    # (dump/restore; 17 -> 18: DT-046).
    pg_major                   = optional(number, 18)
    rgw_endpoints              = optional(list(string), ["10.27.0.12:7480", "10.27.0.13:7480", "10.27.0.17:7480"])
    retention_days             = optional(number, 14)               # PITR window (pgBackRest time-based full retention)
    backup_schedule            = optional(string, "*-*-* 01:30:00") # systemd OnCalendar: daily full backup on the leader
    archive_timeout            = optional(number, 300)              # s: a WAL segment is archived at least this often when there are writes (RPO)
    maximum_lag_on_failover    = optional(number, 1048576)          # bytes: replicas further behind don't take over
    max_connections            = optional(number, 200)              # cluster-wide: only at bootstrap, later via pgctl edit-config
    parameters                 = optional(map(string), {})          # extra/overriding local postgresql.conf parameters
    etcd_initial_cluster_state = optional(string, "new")            # "existing" when a rebuilt member rejoins (README)
    etcd_heartbeat_interval    = optional(number, 300)              # ms (etcd default 100): Ceph RBD fsync p99 is 125-355 ms (DT-017)
    etcd_election_timeout      = optional(number, 3000)             # ms (etcd default 1000): ~10x the heartbeat, per the etcd tuning guide
    grafana_on_cluster         = optional(bool, false)              # Grafana uses the VIP (after the runbook's dump/restore)
    legacy_on_primary          = optional(bool, true)               # keep the primary backend's Postgres container
    bootstrap_from_backup      = optional(bool, false)              # disaster recovery: bootstrap a fresh cluster from pgBackRest (README)
    restore_target_time        = optional(string)                   # with bootstrap_from_backup: PITR target, e.g. "2026-11-20 12:00:00+00"
    # Package => accepted version (shell glob). postgresql-<pg_major> = "<pg_major>.*" is added
    # unless set here. An installed package outside its series is upgraded to the apt candidate.
    package_versions = optional(map(string), {
      "patroni"     = "4.1.*"  # PGDG (PostgreSQL 18 needs Patroni >= 4.1)
      "etcd-server" = "3.5.*"  # Debian
      "pgbackrest"  = "2.60.*" # PGDG
    })
  })
  default = {}
  validation {
    condition = (
      can(cidrhost(var.postgres_settings.vip, 0)) && var.postgres_settings.vrrp_router_id >= 1 && var.postgres_settings.vrrp_router_id <= 255 &&
      can(regex("^[a-z0-9][a-z0-9-]*$", var.postgres_settings.cluster_name)) &&
      length(var.postgres_settings.rgw_endpoints) > 0 && alltrue([for e in var.postgres_settings.rgw_endpoints : can(regex("^[0-9.]+:[0-9]+$", e))]) &&
      var.postgres_settings.retention_days >= 1 && contains(["new", "existing"], var.postgres_settings.etcd_initial_cluster_state) &&
      var.postgres_settings.etcd_heartbeat_interval >= 10 && var.postgres_settings.etcd_election_timeout >= 5 * var.postgres_settings.etcd_heartbeat_interval &&
      var.postgres_settings.etcd_election_timeout <= 50000 &&
      floor(var.postgres_settings.pg_major) == var.postgres_settings.pg_major && var.postgres_settings.pg_major >= 17 &&
      alltrue([for k, v in var.postgres_settings.package_versions : can(regex("^[a-z0-9.+-]+$", k)) && can(regex("^[A-Za-z0-9.+~:*-]+$", v))])
    )
    error_message = "postgres_settings: vip is an IPv4 CIDR, vrrp_router_id 1..255, cluster_name lowercase [a-z0-9-], rgw_endpoints \"IP:port\", retention_days >= 1, etcd_initial_cluster_state new|existing, etcd_heartbeat_interval >= 10 ms, etcd_election_timeout 5x the heartbeat .. 50000 ms, pg_major an integer >= 17, package_versions package => version glob."
  }
}

variable "postgres_apps" {
  description = "Application databases on the Patroni cluster: database = role = key; clients = the app VMs' backend addresses (pg_hba hostssl + postgres-guard). Passwords in postgres_app_passwords."
  type = map(object({
    clients = list(string)
    # Non-empty: a read-only role "<app>_grafana" (password postgres_app_passwords["<app>_grafana"])
    # gets these privileges in the app's database ("SELECT ON tickets", "SELECT (id, name) ON users"),
    # pg_hba admits it from the Grafana VMs, and Grafana gets a PostgreSQL datasource (uid = app).
    grafana_grants = optional(list(string), [])
  }))
  default = {}
  validation {
    condition     = alltrue([for k, a in var.postgres_apps : can(regex("^[a-z][a-z0-9_]{0,30}$", k)) && !contains(["grafana", "postgres", "pgmon", "replicator"], k) && alltrue([for ip in a.clients : can(cidrhost("${ip}/32", 0))])])
    error_message = "postgres_apps: keys are lowercase [a-z][a-z0-9_] (not grafana/postgres/pgmon/replicator), clients are IPv4 addresses."
  }
}

variable "postgres_app_passwords" {
  description = "Password per postgres_apps key."
  sensitive   = true
  type        = map(string)
  default     = {}
}

variable "postgres_secrets" {
  description = "pgBackRest's S3 bucket and keys (RGW user), the Patroni superuser/replication/REST API and postgres_exporter passwords. Grafana's role uses secrets.grafana_db_password. null leaves the cluster out."
  sensitive   = true
  type = object({
    s3_bucket            = string
    s3_access_key        = string
    s3_secret_key        = string
    superuser_password   = string
    replication_password = string
    restapi_password     = string
    monitor_password     = string
  })
  default = null
}

variable "rgw_bucket_alerts" {
  description = "Thresholds of the per-bucket Ceph RGW alerts (rgw.tf; metrics from roots/monitoring-config/pve-collectors). Growth is in allocated bytes."
  type = object({
    growth_1h_bytes       = optional(number, 10737418240)  # CephRGWBucketFastGrowth: 10 GiB in an hour
    growth_24h_bytes      = optional(number, 107374182400) # CephRGWBucketGrowth24h: 100 GiB in a day
    quota_ratio           = optional(number, 0.85)         # Near(Bucket|User)Quota
    quota_horizon_days    = optional(number, 7)            # CephRGWBucketQuotaFullSoon
    stats_max_age_seconds = optional(number, 1800)         # CephRGWBucketStatsStale (the timer runs every 5 min)
  })
  default = {}
  validation {
    condition     = var.rgw_bucket_alerts.quota_ratio > 0 && var.rgw_bucket_alerts.quota_ratio <= 1 && var.rgw_bucket_alerts.quota_horizon_days > 0
    error_message = "rgw_bucket_alerts.quota_ratio must be in (0, 1] and quota_horizon_days positive."
  }
}
