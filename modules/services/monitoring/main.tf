locals {
  backend_conf = "/etc/monitoring"
  backend_data = "/var/lib/monitoring"
  grafana_conf = "/etc/grafana-container"
  grafana_data = "/var/lib/grafana-container"
  quadlet_dir  = "/etc/containers/systemd"

  # Backends (backends.tf has the HA pieces). mon/back are the primary's addresses:
  # Postgres, and anything that has to name one backend.
  backend_names = sort(keys(var.backends))
  primary       = var.primary_backend
  mon           = try(var.backends[local.primary].monitoring_address, "0.0.0.0")
  back          = try(var.backends[local.primary].backend_address, "0.0.0.0")

  # Whether a token was given is not secret; the token itself stays sensitive.
  pve_enabled = nonsensitive(var.pve_exporter_token != null)
  # Same for whether SNMPv3 auths were given.
  snmp_auths_enabled = nonsensitive(length(var.snmp_auths) > 0)
  snmp_conf          = "${local.backend_conf}/snmp-exporter"
  snmp_auths_path    = "${local.snmp_conf}/auths.yml"
  # Extra modules on top of the image's bundled snmp.yml (snmp_exporter merges every --config.file):
  # mikrotik_lite, the bundled "mikrotik" module cut down to what the dashboards use (DT-023;
  # snmp/build-mikrotik-lite.sh regenerates it).
  snmp_module_files = { "mikrotik_lite.yml" = file("${path.module}/snmp/mikrotik_lite.yml") }
  snmp_config_files = concat(
    ["/etc/snmp_exporter/snmp.yml"],
    [for f in keys(local.snmp_module_files) : "/etc/snmp_exporter/${f}"],
    local.snmp_auths_enabled ? ["/etc/snmp_exporter/auths.yml"] : [],
  )
  snmp_volumes = concat(
    [for f in keys(local.snmp_module_files) : "${local.snmp_conf}/${f}:/etc/snmp_exporter/${f}:ro"],
    local.snmp_auths_enabled ? ["${local.snmp_auths_path}:/etc/snmp_exporter/auths.yml:ro"] : [],
  )
  snmp_auths_yml = local.snmp_auths_enabled ? yamlencode({
    auths = {
      for name, a in var.snmp_auths : name => {
        version        = 3
        username       = a.username
        security_level = a.security_level
        auth_protocol  = a.auth_protocol
        password       = a.password
        priv_protocol  = a.priv_protocol
        priv_password  = a.priv_password
      }
    }
  }) : ""

  # node_exporter on every VM here (backends, Grafana, logging.tf, metrics.tf, postgres.tf;
  # services-config's DNS template has the same flags). Besides the defaults: the collectors
  # Node Exporter Full graphs that are off by default (processes, tcpstat, interrupts) and
  # systemd, which asks systemd over the host's D-Bus system socket (--path.rootfs doesn't
  # cover that, hence the socket at the path D-Bus clients default to). The default exclude
  # already drops mounts, devices, slices and scopes; unit-include also leaves out targets
  # and paths (~55 units x 5 state series per VM). [.] instead of \. keeps the Quadlet
  # Exec line free of escapes.
  node_exporter_volumes = ["/:/host:ro,rslave", "/run/dbus/system_bus_socket:/var/run/dbus/system_bus_socket:ro"]
  node_exporter_collectors = [
    "--collector.processes",
    "--collector.tcpstat",
    "--collector.interrupts",
    "--collector.systemd",
    "--collector.systemd.unit-include=.+[.](service|socket|timer)",
  ]

  # Rewrites a static target into exporter parameters (the snmp/pve/blackbox pattern).
  proxy_relabel = {
    for name, address in {
      snmp     = "snmp-exporter:9116"
      pve      = "pve-exporter:9221"
      blackbox = "blackbox-exporter:9115"
      } : name => [
      { source_labels = ["__address__"], target_label = "__param_target" },
      { source_labels = ["__param_target"], target_label = "instance" },
      { target_label = "__address__", replacement = address },
    ]
  }

  scrape_configs = concat(
    [
      # Every backend's Prometheus, Alertmanager and SNMP/blackbox exporters, by
      # backend-VLAN address with host = backend: each replica scrapes all of them, so
      # Mimir's HA dedup (it keeps one replica's samples) still has every instance's metrics.
      {
        job_name       = "prometheus"
        static_configs = [for name in local.backend_names : { targets = ["${var.backends[name].backend_address}:9090"], labels = { host = name } }]
      },
      {
        job_name       = "alertmanager"
        static_configs = [for name in local.backend_names : { targets = ["${var.backends[name].backend_address}:9093"], labels = { host = name } }]
      },
      {
        job_name       = "snmp-exporter"
        static_configs = [for name in local.backend_names : { targets = ["${var.backends[name].backend_address}:9116"], labels = { host = name } }]
      },
      {
        job_name       = "blackbox-exporter"
        static_configs = [for name in local.backend_names : { targets = ["${var.backends[name].backend_address}:9115"], labels = { host = name } }]
      },
      {
        # InfluxDB 2's own /metrics (no auth): write/query rates, storage shards and compactions, tasks.
        job_name       = "influxdb"
        static_configs = [for name in local.backend_names : { targets = ["${var.backends[name].backend_address}:8086"], labels = { host = name } }]
      },
      {
        job_name = "node"
        static_configs = [for t in var.targets.node : {
          targets = ["${t.address}:9100"], labels = merge({ host = t.host }, t.labels)
        }]
      },
      {
        job_name = "vyos-node"
        static_configs = [for t in var.targets.vyos : {
          targets = ["${t.address}:9100"], labels = merge({ host = t.host }, t.labels)
        }]
      },
      {
        job_name = "vyos-frr"
        static_configs = [for t in var.targets.vyos : {
          targets = ["${t.address}:9342"], labels = merge({ host = t.host }, t.labels)
        }]
      },
      {
        job_name       = "grafana"
        static_configs = [for t in var.targets.grafana : { targets = ["${t.address}:3000"], labels = { host = t.host } }]
      },
    ],
    # Only the active mgr serves metrics; standbys answer with an empty 200. Every
    # mgr host is listed so a failover needs no config change. The mgr's own
    # instance labels (OSD hostnames on ceph_disk_occupation etc.) are kept, and
    # the rest get instance="ceph_cluster" with no host label, so series don't
    # change identity when the active mgr moves. up{job="ceph"} keeps per-host labels.
    # Telegraf on VyOS (firewall rule counters, interfaces, services, conntrack...).
    # Its metrics already carry host=<router>, the same as the target label.
    length(var.targets.telegraf) == 0 ? [] : [{
      job_name       = "vyos-telegraf"
      honor_labels   = true
      static_configs = [for t in var.targets.telegraf : { targets = ["${t.address}:9273"], labels = { host = t.host, role = "router" } }]
      # The syslog input carries each log message as a label (one new series per
      # line); the dashboards read syslog from InfluxDB instead.
      metric_relabel_configs = [{ source_labels = ["__name__"], regex = "syslog_.*", action = "drop" }]
    }],
    length(var.targets.ceph) == 0 ? [] : [{
      job_name        = "ceph"
      honor_labels    = true
      scrape_interval = "15s"
      static_configs  = [for t in var.targets.ceph : { targets = ["${t.address}:9283"], labels = { host = t.host, cluster = var.settings.ceph_cluster_name } }]
      metric_relabel_configs = [
        { action = "labeldrop", regex = "host" },
        { source_labels = ["instance"], regex = ".*:9283", target_label = "instance", replacement = "ceph_cluster" },
      ]
    }],
    # Slow agents (the MikroTiks walk if_mib + mikrotik in 7-10 s) get their own interval/timeout.
    [for name, job in var.targets.snmp : merge({
      job_name        = "snmp-${name}"
      metrics_path    = "/snmp"
      params          = { module = job.modules, auth = [job.auth] }
      static_configs  = [for host, address in job.targets : { targets = [address], labels = { host = host } }]
      relabel_configs = local.proxy_relabel.snmp
      }, job.scrape_interval == null ? {} : { scrape_interval = job.scrape_interval },
      job.scrape_timeout == null ? {} : { scrape_timeout = job.scrape_timeout },
    )],
    local.pve_enabled ? [{
      job_name        = "pve"
      metrics_path    = "/pve"
      params          = { module = ["default"], cluster = ["1"], node = ["1"] }
      static_configs  = [for t in var.targets.pve : { targets = [t.address], labels = { host = t.host } }]
      relabel_configs = local.proxy_relabel.pve
    }] : [],
    [for module, targets in var.targets.blackbox : {
      job_name        = "blackbox-${module}"
      metrics_path    = "/probe"
      params          = { module = [module] }
      static_configs  = [for t in targets : { targets = [t.target], labels = { host = t.host } }]
      relabel_configs = local.proxy_relabel.blackbox
    }],
    local.logging_scrape_configs,  # logging.tf
    local.wlc_scrape_configs,      # telemetry.tf
    local.mimir_scrape_configs,    # metrics.tf
    local.postgres_scrape_configs, # postgres.tf
    local.valkey_scrape_configs,   # valkey.tf
    local.nginx_scrape_configs,    # nginx.tf
    local.bind_scrape_configs,     # bind.tf
    # NetBox (django-prometheus; services-config runs it in multiprocess mode, so one scrape
    # covers every Granian worker).
    length(var.targets.netbox) == 0 ? [] : [{
      job_name       = "netbox"
      static_configs = [for t in var.targets.netbox : { targets = ["${t.address}:80"], labels = { host = t.host } }]
    }],
  )

  # One per backend: the same scrapes and rules, only __replica__ differs. Mimir's HA
  # tracker keeps one replica's samples (ha_cluster/__replica__) and then drops ha_cluster
  # and site, so stored series look like each Prometheus's own (and the backfill).
  prometheus_yml = {
    for name in local.backend_names : name => yamlencode(merge({
      global = {
        scrape_interval     = "30s"
        evaluation_interval = "30s"
        external_labels     = { site = "lylat", ha_cluster = "lylat", __replica__ = name }
      }
      alerting = {
        # Both replicas fire the same alerts; without __replica__ they're identical and
        # the Alertmanager cluster sends them once.
        alert_relabel_configs = [{ action = "labeldrop", regex = "__replica__" }]
        alertmanagers         = [{ static_configs = [{ targets = local.alertmanager_targets }] }]
      }
      rule_files     = ["/etc/prometheus/rules/*.yml"]
      scrape_configs = local.scrape_configs
    }, length(local.mimir_remote_write) > 0 ? { remote_write = local.mimir_remote_write } : {})) # metrics.tf
  }

  rules_yml = yamlencode({
    groups = concat([{
      name = "basic"
      rules = [
        {
          alert       = "TargetDown"
          expr        = "up == 0"
          for         = "5m"
          labels      = { severity = "warning" }
          annotations = { summary = "{{ $labels.job }} target {{ $labels.instance }} is down" }
        },
        {
          alert       = "ProbeFailed"
          expr        = "probe_success == 0"
          for         = "2m"
          labels      = { severity = "critical" }
          annotations = { summary = "{{ $labels.job }} probe to {{ $labels.instance }} is failing" }
        },
        {
          alert       = "FilesystemAlmostFull"
          expr        = "node_filesystem_avail_bytes{fstype!~\"tmpfs|overlay\"} / node_filesystem_size_bytes{fstype!~\"tmpfs|overlay\"} < 0.10"
          for         = "15m"
          labels      = { severity = "warning" }
          annotations = { summary = "{{ $labels.instance }} {{ $labels.mountpoint }} has under 10% free" }
        },
      ]
    }], local.storage_health_rules, local.logging_rules, local.wlc_rules, local.mimir_rules, local.backend_rules, local.postgres_rules, local.rgw_rules, local.valkey_rules, local.nginx_rules, local.bind_rules) # logging.tf, telemetry.tf, metrics.tf, backends.tf, postgres.tf, rgw.tf, valkey.tf, nginx.tf, bind.tf
  })

  # Per-OSD BlueStore stalls (the mixin only has the cluster-wide BLUESTORE_SLOW_OP_ALERT health
  # check, which stays WARN for a day and masks a new OSD joining). Log review 2026-11-10 #3:
  # SATA link resets on the Seagate OSDs froze NCQ for up to 30 s. Pairs with the Loki rule
  # SataLinkReset (logging.tf).
  storage_health_rules = length(var.targets.ceph) == 0 ? [] : [{
    name = "storage-health"
    rules = [
      {
        alert       = "CephOSDSlowCommits"
        expr        = "sum by (ceph_daemon) (increase(ceph_bluestore_slow_committed_kv_count[1h])) > 0"
        labels      = { severity = "warning" }
        annotations = { summary = "{{ $labels.ceph_daemon }}: {{ $value | humanize }} slow BlueStore kv commits in the last hour (check its disk/SATA link)" }
      },
      {
        alert       = "CephOSDSlowAIO"
        expr        = "sum by (ceph_daemon) (increase(ceph_bluestore_slow_aio_wait_count[1h])) > 0"
        labels      = { severity = "warning" }
        annotations = { summary = "{{ $labels.ceph_daemon }}: {{ $value | humanize }} slow BlueStore AIO waits in the last hour" }
      },
      # One alert per active HEALTH_WARN check (DT-020). The mixin's CephHealthWarning only sees
      # ceph_health_status == 1, so one long-lived check (BLUESTORE_SLOW_OP_ALERT for days) pins
      # it and hides any check that starts after it. Alertmanager inhibits CephHealthWarning
      # while one of these fires; it stays as the fallback for a WARN without a detail series.
      {
        alert       = "CephHealthCheckWarn"
        expr        = "ceph_health_detail{job=\"ceph\",severity=\"HEALTH_WARN\"} == 1"
        for         = "15m"
        labels      = { severity = "warning" }
        annotations = { summary = "Ceph health check {{ $labels.name }} is active on cluster {{ $labels.cluster }} (ceph health detail)" }
      },
    ]
  }]

  # The ceph-mixin's alerts (rules/ceph-mixin/, vendored from the commit the Ceph dashboards
  # come from: they back the dashboards' Firing Alerts/Alerts panels). Its own file, loaded
  # like the others and routed like them. Changed on the way: the "nodes" group's node_*
  # selectors get settings.ceph_node_selector (by default the PVE cluster's nodes), because
  # node_exporter runs on every host here, not just on the Ceph nodes (unfiltered,
  # CephNodeInconsistentMTU fires for each VyOS interface whose MTU differs from the
  # median of all hosts' same-named interfaces, CephNodeDiskspaceWarning for any VM).
  ceph_alerts_enabled = length(var.targets.ceph) > 0
  ceph_node_sel = (var.settings.ceph_node_selector != null ? var.settings.ceph_node_selector
    : length(var.targets.pve) == 0 ? "" : "host=~\"${join("|", sort([for t in var.targets.pve : t.host]))}\""
  )
  # Groups from the Ceph mixin that reference metrics which don't exist on a
  # non-cephadm (PVE) cluster are skipped (DT-039).
  ceph_alert_skip = toset(["hardware", "nvmeof", "rbdmirror", "cephadm"])
  ceph_alert_groups = [for g in yamldecode(file("${path.module}/rules/ceph-mixin/prometheus_alerts.yml")).groups : g
    if !contains(local.ceph_alert_skip, g.name)
  ]
  ceph_alerts_yml = local.ceph_alerts_enabled ? yamlencode({
    groups = [for g in local.ceph_alert_groups : {
      name = g.name
      rules = [for r in g.rules : merge(r, {
        # 1: node_x{...} -> node_x{<sel>,...}; 2: a bare node_x -> node_x{<sel>} (now
        # every node_x left without a "{" after it).
        expr = g.name != "nodes" || local.ceph_node_sel == "" ? r.expr : replace(
          replace(r.expr, "/\\b(node_[a-z_]+)\\{/", "$${1}{${local.ceph_node_sel},"),
          "/\\b(node_[a-z_]+)([^a-z_{]|$)/", "$${1}{${local.ceph_node_sel}}$${2}",
        )
      })]
    }]
  }) : ""

  # Placeholder routing: alerts are visible in Alertmanager/Grafana but not sent anywhere yet.
  alertmanager_yml = yamlencode({
    # group_by name: each Ceph health check (CephHealthCheckWarn) is its own group (DT-020).
    route = {
      receiver        = "null"
      group_by        = ["alertname", "job", "name"]
      group_wait      = "30s"
      group_interval  = "5m"
      repeat_interval = "4h"
    }
    receivers = [{ name = "null" }]
    inhibit_rules = [{
      source_matchers = ["alertname=\"CephHealthCheckWarn\""]
      target_matchers = ["alertname=\"CephHealthWarning\""]
      equal           = ["cluster"]
    }]
  })

  blackbox_yml = yamlencode({
    modules = {
      icmp     = { prober = "icmp", timeout = "5s", icmp = { preferred_ip_protocol = "ip4" } }
      http_2xx = { prober = "http", timeout = "5s", http = { preferred_ip_protocol = "ip4" } }
      # The published sites through the reverse proxy: must be HTTPS with a valid cert (also gives
      # probe_ssl_earliest_cert_expiry for the expiry alert in nginx.tf).
      https = { prober = "http", timeout = "5s", http = { preferred_ip_protocol = "ip4", fail_if_not_ssl = true } }
      dns_soa = {
        prober  = "dns"
        timeout = "5s"
        dns = {
          transport_protocol    = "udp"
          preferred_ip_protocol = "ip4"
          query_name            = var.settings.dns_probe_zone
          query_type            = "SOA"
          valid_rcodes          = ["NOERROR"]
        }
      }
    }
  })

  pve_yml = local.pve_enabled ? yamlencode({
    default = {
      user        = var.pve_exporter_token.user
      token_name  = var.pve_exporter_token.token_name
      token_value = var.pve_exporter_token.value
      verify_ssl  = false
    }
  }) : ""

  datasources_yml = yamlencode({
    apiVersion = 1
    datasources = concat([
      {
        # uid "prometheus" is what the dashboards use: Mimir when it's on (metrics.tf),
        # else the primary's Prometheus.
        name      = "Prometheus"
        uid       = "prometheus"
        type      = "prometheus"
        access    = "proxy"
        url       = coalesce(local.mimir_query_url, "http://${local.back}:9090")
        isDefault = true
        jsonData  = merge({ timeInterval = "30s" }, local.mimir_datasource_json) # metrics.tf
      },
      {
        # Any member of the Alertmanager cluster shows the same alerts and silences.
        name     = "Alertmanager"
        uid      = "alertmanager"
        type     = "alertmanager"
        access   = "proxy"
        url      = "http://${local.backend_service_host}:9093"
        jsonData = { implementation = "prometheus" }
      },
      {
        name           = "InfluxDB"
        uid            = "influxdb"
        type           = "influxdb"
        access         = "proxy"
        url            = "http://${local.backend_service_host}:8086"
        jsonData       = { version = "Flux", organization = var.settings.influxdb_org, defaultBucket = var.settings.influxdb_grafana_bucket }
        secureJsonData = { token = "$INFLUXDB_TOKEN" } # Expanded by Grafana from grafana.env.
      },
      ],
      # Each replica's own Prometheus (debugging, comparing replicas). backends.tf
      [for name in local.backend_names : {
        name   = "Prometheus ${name}"
        uid    = "prometheus-${name}"
        type   = "prometheus"
        access = "proxy"
        url    = "http://${var.backends[name].backend_address}:9090"
        # Both replicas load the same rule files: only the primary's are listed in Grafana's alert
        # views (alert list panels, Alerting > Data source-managed), so each alert shows once.
        jsonData = merge({ timeInterval = "30s" }, name == local.primary ? {} : { manageAlerts = false })
      }],
      local.loki_datasource, # logging.tf
      # Read-only PostgreSQL datasources of the app databases on the Patroni cluster (postgres.tf).
      [for app in local.pg_grafana_apps : {
        name     = app == "triage" ? "dark-triage" : app
        uid      = app
        type     = "grafana-postgresql-datasource"
        access   = "proxy"
        url      = "${local.pg_vip}:5432"
        user     = "${app}_grafana"
        jsonData = { database = app, sslmode = "require", postgresVersion = 1700, timescaledb = false, maxOpenConns = 5, maxIdleConns = 2, connMaxLifetime = 14400 }
        # Expanded by Grafana from grafana.env.
        secureJsonData = { password = "$PG_APP_${upper(app)}_GRAFANA_PASSWORD" }
    }])
  })

  # Dashboards: dashboards/<Folder>/<name>.json becomes Grafana folder <Folder>.
  # Files are minified (and so checked to be valid JSON) at plan time.
  dashboards_dir = "${local.grafana_conf}/provisioning/dashboards/files"
  dashboards = {
    for rel in fileset("${path.module}/dashboards", "**/*.json") :
    rel => jsonencode(jsondecode(file("${path.module}/dashboards/${rel}")))
  }
  dashboard_dirs = sort(distinct([for rel in keys(local.dashboards) : dirname(rel) if dirname(rel) != "."]))
  # Grafana's home page (until a user, team or org preference overrides it). Left
  # unset if the file is gone, so Grafana falls back to its own home page.
  home_dashboard      = "Overview/overview.json"
  home_dashboard_path = contains(keys(local.dashboards), local.home_dashboard) ? "/etc/grafana/provisioning/dashboards/files/${local.home_dashboard}" : null

  dashboard_providers_yml = yamlencode({
    apiVersion = 1
    providers = [{
      name                  = "lylat"
      orgId                 = 1
      type                  = "file"
      disableDeletion       = false # Removing a JSON file removes its dashboard.
      allowUiUpdates        = false # Change the JSON in git; the UI can't save over it.
      updateIntervalSeconds = 30    # New or changed JSON is picked up without a restart.
      options = {
        path                      = "/etc/grafana/provisioning/dashboards/files"
        foldersFromFilesStructure = true
      }
    }]
  })

  # One container unit per service and backend. "reload" adds ExecReload (SIGHUP) for
  # config-only changes. A {for} expression keeps the per-service object shapes (merge
  # with a conditional {} would need identical types). Postgres runs on the primary only;
  # Telegraf (WLC telemetry) where wlc_telemetry.backends lists the backend.
  backend_containers = {
    for host in local.backend_names : host => {
      for name, c in merge(local.backend_container_defs[host], local.wlc_container[host]) : name => c # telemetry.tf
      if(name != "pve-exporter" || local.pve_enabled) && (name != "telegraf" || contains(local.wlc_backends, host)) && (name != "postgres" || (host == local.primary && local.legacy_postgres))
    }
  }
  backend_container_defs = {
    for host, b in var.backends : host => {
      prometheus = {
        description = "Prometheus"
        image       = var.images.prometheus
        publish     = ["${b.monitoring_address}:9090:9090", "${b.backend_address}:9090:9090"]
        volumes     = ["${local.backend_conf}/prometheus:/etc/prometheus:ro", "${local.backend_data}/prometheus:/prometheus"]
        exec = [
          "--config.file=/etc/prometheus/prometheus.yml",
          "--storage.tsdb.path=/prometheus",
          "--storage.tsdb.retention.time=${var.settings.prometheus_retention_time}",
          "--storage.tsdb.retention.size=${var.settings.prometheus_retention_size}",
          "--web.external-url=http://${b.monitoring_address}:9090/",
          "--web.enable-lifecycle",
        ]
        reload = true
      }
      alertmanager = {
        description = "Prometheus Alertmanager"
        image       = var.images.alertmanager
        # Also on the backend VIP (Grafana's Alertmanager datasource) and the gossip port. backends.tf
        publish = concat(
          ["${b.monitoring_address}:9093:9093", "${b.backend_address}:9093:9093"],
          [for vip in local.backend_vip_backend : "${vip}:9093:9093"],
          local.am_cluster_publish[host],
        )
        volumes = ["${local.backend_conf}/alertmanager:/etc/alertmanager:ro", "${local.backend_data}/alertmanager:/alertmanager"]
        exec = concat([
          "--config.file=/etc/alertmanager/alertmanager.yml",
          "--storage.path=/alertmanager",
          "--web.external-url=http://${b.monitoring_address}:9093/",
        ], local.am_cluster_args[host])
        reload = true
      }
      snmp-exporter = {
        description = "Prometheus SNMP exporter (bundled snmp.yml, mikrotik_lite, plus SNMPv3 auths when given)"
        image       = var.images.snmp_exporter
        # The probes go to the container by name; the backend address is for the other
        # replica's self-scrape (job snmp-exporter), like Prometheus's own port.
        publish = ["${b.backend_address}:9116:9116"]
        volumes = local.snmp_volumes
        exec    = [for f in local.snmp_config_files : "--config.file=${f}"]
      }
      blackbox-exporter = {
        description = "Prometheus blackbox exporter"
        image       = var.images.blackbox_exporter
        publish     = ["${b.backend_address}:9115:9115"] # as snmp-exporter
        volumes     = ["${local.backend_conf}/blackbox:/etc/blackbox_exporter:ro"]
        exec        = ["--config.file=/etc/blackbox_exporter/config.yml"]
        # Raw ICMP sockets need root plus CAP_NET_RAW inside the container.
        user   = "0"
        caps   = ["CAP_NET_RAW"]
        reload = true
      }
      influxdb = {
        description = "InfluxDB 2 (Proxmox metric server target)"
        image       = var.images.influxdb
        # Also on both VIPs (backends.tf): influxdb-vip on the monitoring network and Grafana's datasource.
        publish = concat(
          ["${b.monitoring_address}:8086:8086", "${b.backend_address}:8086:8086"],
          [for vip in concat(local.backend_vip_monitoring, local.backend_vip_backend) : "${vip}:8086:8086"],
        )
        volumes = ["${local.backend_data}/influxdb/data:/var/lib/influxdb2", "${local.backend_data}/influxdb/config:/etc/influxdb2"]
        env = {
          DOCKER_INFLUXDB_INIT_MODE      = "setup"
          DOCKER_INFLUXDB_INIT_USERNAME  = "admin"
          DOCKER_INFLUXDB_INIT_ORG       = var.settings.influxdb_org
          DOCKER_INFLUXDB_INIT_BUCKET    = var.settings.influxdb_bucket
          DOCKER_INFLUXDB_INIT_RETENTION = var.settings.influxdb_retention
        }
        env_files = ["${local.backend_conf}/influxdb.env"]
        # influxd exits 2 on SIGTERM; without this every stop/restart leaves the unit "failed".
        service = ["SuccessExitStatus=2"]
      }
      postgres = {
        description = "PostgreSQL for the shared Grafana database"
        image       = var.images.postgres
        publish     = ["${b.backend_address}:5432:5432"]
        volumes     = ["${local.backend_data}/postgres:/var/lib/postgresql/data"]
        env         = { POSTGRES_USER = "grafana", POSTGRES_DB = "grafana" }
        env_files   = ["${local.backend_conf}/postgres.env"]
      }
      node-exporter = {
        description = "Prometheus node exporter"
        image       = var.images.node_exporter
        network     = "host"
        volumes     = local.node_exporter_volumes
        podman_args = ["--pid=host"]
        # address-info: node_network_address_info shows which backend holds each VIP.
        exec = concat(["--path.rootfs=/host", "--web.listen-address=${b.monitoring_address}:9100", "--collector.netdev.address-info"], local.node_exporter_collectors)
      }
      pve-exporter = {
        description = "Prometheus Proxmox VE exporter"
        image       = var.images.pve_exporter
        volumes     = ["${local.backend_conf}/pve-exporter/pve.yml:/etc/prometheus/pve.yml:ro"]
      }
    }
  }

  # Restart and health order on each backend.
  backend_order = {
    for host in local.backend_names : host => [
      for name in ["postgres", "influxdb", "telegraf", "snmp-exporter", "blackbox-exporter", "pve-exporter", "alertmanager", "prometheus", "node-exporter"] : name
      if contains(keys(local.backend_containers[host]), name)
    ]
  }

  backend_units = {
    for host in local.backend_names : host => {
      # c.service: extra [Service] lines (the shared template has no variable for them).
      for name, c in local.backend_containers[host] : name => replace(templatefile("${path.module}/templates/container.tftpl", {
        name        = name
        description = c.description
        image       = c.image
        network     = try(c.network, "monitoring.network")
        publish     = try(c.publish, [])
        volumes     = try(c.volumes, [])
        env         = try(c.env, {})
        env_files   = try(c.env_files, [])
        exec        = try(c.exec, [])
        user        = try(c.user, null)
        caps        = try(c.caps, [])
        podman_args = try(c.podman_args, [])
        reload      = try(c.reload, false)
      }), "[Service]\n", join("\n", concat(["[Service]"], try(c.service, []), [""])))
    }
  }

  backend_files = {
    for host in local.backend_names : host => concat(
      [{
        path    = "${local.quadlet_dir}/monitoring.network"
        mode    = "0644"
        owner   = "root"
        content = file("${path.module}/templates/monitoring.network")
        restart = ["monitoring-network"]
        reload  = []
      }],
      [for name in local.backend_order[host] : {
        path    = "${local.quadlet_dir}/${name}.container"
        mode    = "0644"
        owner   = "root"
        content = local.backend_units[host][name]
        restart = [name]
        reload  = []
      }],
      [
        { path = "${local.backend_conf}/prometheus/prometheus.yml", mode = "0644", owner = "root", content = local.prometheus_yml[host], restart = [], reload = ["prometheus"] },
        { path = "${local.backend_conf}/prometheus/rules/basic.yml", mode = "0644", owner = "root", content = local.rules_yml, restart = [], reload = ["prometheus"] },
        { path = "${local.backend_conf}/alertmanager/alertmanager.yml", mode = "0644", owner = "root", content = local.alertmanager_yml, restart = [], reload = ["alertmanager"] },
        { path = "${local.backend_conf}/blackbox/config.yml", mode = "0644", owner = "root", content = local.blackbox_yml, restart = [], reload = ["blackbox-exporter"] },
      ],
      local.ceph_alerts_enabled ? [
        { path = "${local.backend_conf}/prometheus/rules/ceph.yml", mode = "0644", owner = "root", content = local.ceph_alerts_yml, restart = [], reload = ["prometheus"] },
      ] : [],
      [
        {
          path    = "${local.backend_conf}/influxdb.env"
          mode    = "0600"
          owner   = "root"
          content = "DOCKER_INFLUXDB_INIT_PASSWORD=${var.secrets.influxdb_admin_password}\nDOCKER_INFLUXDB_INIT_ADMIN_TOKEN=${var.secrets.influxdb_admin_token}\n"
          restart = ["influxdb"]
          reload  = []
        },
      ],
      host == local.primary && local.legacy_postgres ? [{ # postgres.tf
        path    = "${local.backend_conf}/postgres.env"
        mode    = "0600"
        owner   = "root"
        content = "POSTGRES_PASSWORD=${var.secrets.grafana_db_password}\n"
        restart = ["postgres"]
        reload  = []
      }] : [],
      local.pve_enabled ? [{
        # Readable by the exporter's runtime user only.
        path    = "${local.backend_conf}/pve-exporter/pve.yml"
        mode    = "0640"
        owner   = "runtime|${var.images.pve_exporter}"
        content = local.pve_yml
        restart = ["pve-exporter"]
        reload  = []
      }] : [],
      local.alloy_files[host], # logging.tf
      [for f, content in local.snmp_module_files : {
        path    = "${local.snmp_conf}/${f}"
        mode    = "0644"
        owner   = "root"
        content = content
        restart = ["snmp-exporter"]
        reload  = []
      }],
      local.snmp_auths_enabled ? [{
        # SNMPv3 credentials; the exporter image runs as root.
        path    = local.snmp_auths_path
        mode    = "0600"
        owner   = "root"
        content = local.snmp_auths_yml
        restart = ["snmp-exporter"]
        reload  = []
      }] : [],
      local.wlc_files[host],        # telemetry.tf
      local.backend_ha_files[host], # backends.tf
    )
  }

  backend_dirs = {
    for host in local.backend_names : host => concat(
      [
        { path = local.quadlet_dir, mode = "0755", owner = "root" },
        { path = local.backend_conf, mode = "0755", owner = "root" },
        { path = "${local.backend_conf}/prometheus", mode = "0755", owner = "root" },
        { path = "${local.backend_conf}/prometheus/rules", mode = "0755", owner = "root" },
        { path = "${local.backend_conf}/alertmanager", mode = "0755", owner = "root" },
        { path = "${local.backend_conf}/blackbox", mode = "0755", owner = "root" },
        { path = local.backend_data, mode = "0755", owner = "root" },
        { path = "${local.backend_data}/prometheus", mode = "0750", owner = "runtime|${var.images.prometheus}" },
        { path = "${local.backend_data}/alertmanager", mode = "0750", owner = "runtime|${var.images.alertmanager}" },
        # The InfluxDB and Postgres images start as root and drop to a service user.
        # Their data dirs must stay owned by that user: their entrypoints chown
        # only at container start, so forcing root here would lock out a server
        # that this deployment doesn't restart.
        { path = "${local.backend_data}/influxdb", mode = "0755", owner = "root" },
        { path = "${local.backend_data}/influxdb/data", mode = "0700", owner = "user|${var.images.influxdb}|influxdb" },
        { path = "${local.backend_data}/influxdb/config", mode = "0700", owner = "user|${var.images.influxdb}|influxdb" },
      ],
      host == local.primary ? [{ path = "${local.backend_data}/postgres", mode = "0700", owner = "user|${var.images.postgres}|postgres" }] : [],
      local.pve_enabled ? [{ path = "${local.backend_conf}/pve-exporter", mode = "0755", owner = "root" }] : [],
      [{ path = local.snmp_conf, mode = "0755", owner = "root" }],
      local.alloy_dirs,
      local.wlc_dirs[host],  # telemetry.tf
      local.backend_ha_dirs, # backends.tf
    )
  }

  backend_validations = {
    for host in local.backend_names : host => concat([
      "podman run --rm --network=none --user 0 --entrypoint promtool -v \"$root${local.backend_conf}/prometheus:/etc/prometheus:ro\" '${var.images.prometheus}' check config /etc/prometheus/prometheus.yml",
      ], local.ceph_alerts_enabled ? [
      # check config covers rules/*.yml too; this names the vendored file if it's the one that breaks.
      "podman run --rm --network=none --user 0 --entrypoint promtool -v \"$root${local.backend_conf}/prometheus:/etc/prometheus:ro\" '${var.images.prometheus}' check rules /etc/prometheus/rules/ceph.yml",
      ] : [], [
      "podman run --rm --network=none --user 0 --entrypoint amtool -v \"$root${local.backend_conf}/alertmanager:/etc/alertmanager:ro\" '${var.images.alertmanager}' check-config /etc/alertmanager/alertmanager.yml",
      "podman run --rm --network=none --user 0 -v \"$root${local.backend_conf}/blackbox:/etc/blackbox_exporter:ro\" '${var.images.blackbox_exporter}' --config.check --config.file=/etc/blackbox_exporter/config.yml",
      local.alloy_validation[host],
      # Loads the bundled snmp.yml with our modules (and auths) exactly as the container does.
      "podman run --rm --network=none ${join(" ", [for v in local.snmp_volumes : "-v \"$root${v}\""])} '${var.images.snmp_exporter}' --dry-run ${join(" ", [for f in local.snmp_config_files : "--config.file=${f}"])}",
    ], local.wlc_validations[host], local.backend_ha_validations) # telemetry.tf, backends.tf
  }

  backend_health = {
    for host, b in var.backends : host => concat(
      [
        "curl -fsS -o /dev/null --max-time 3 http://${b.backend_address}:9090/-/ready",
        "curl -fsS -o /dev/null --max-time 3 http://${b.backend_address}:9093/-/ready",
        "curl -fsS -o /dev/null --max-time 3 http://${b.backend_address}:8086/health",
      ],
      host == local.primary && local.legacy_postgres ? ["podman exec postgres pg_isready -q -U grafana -d grafana"] : [], # postgres.tf
      [local.alloy_health[host]],
      local.wlc_health[host], # telemetry.tf
    )
  }

  backend_services = {
    for host in local.backend_names : host => concat(["monitoring-network"], local.backend_order[host], ["alloy"], local.backend_ha_services)
  }

  backend_deployments = {
    for host in local.backend_names : host => templatefile("${path.module}/templates/deploy.sh.tftpl", {
      host         = host
      state_file   = "${local.backend_conf}/.tofu-quadlets"
      images       = distinct(concat([for c in values(local.backend_containers[host]) : c.image], [var.images.alloy]))
      packages     = local.backend_ha_packages
      apt          = null
      dirs         = local.backend_dirs[host]
      prune_dirs   = []
      files        = local.backend_files[host]
      validations  = local.backend_validations[host]
      post_install = concat(local.backend_ha_post_install, local.backend_relay_cleanup) # backends.tf
      services     = local.backend_services[host]
      health       = local.backend_health[host]
    })
  }

  # Grafana front ends.
  # Alerting HA gossip: over the HA VLAN when every VM has an address there (grafana-ha.tf).
  grafana_peers = join(",", sort([for name in sort(keys(var.grafana)) : "${local.grafana_gossip[name]}:9094"]))

  # Quadlet units per Grafana VM (no secrets; those live in grafana.env).
  grafana_units = {
    for name, g in var.grafana : name => {
      grafana = templatefile("${path.module}/templates/container.tftpl", {
        name        = "grafana"
        description = "Grafana"
        image       = var.images.grafana
        network     = null # Default podman bridge; reaches the backend through the host.
        # UI on every address, so the keepalived VIP (grafana-ha.tf) works wherever it lands.
        publish = ["3000:3000", "${local.grafana_gossip[name]}:9094:9094/tcp", "${local.grafana_gossip[name]}:9094:9094/udp"]
        volumes = ["${local.grafana_conf}/provisioning:/etc/grafana/provisioning:ro", "${local.grafana_data}:/var/lib/grafana"]
        env = merge({
          GF_SERVER_ROOT_URL                       = var.settings.grafana_root_url
          GF_SECURITY_ADMIN_USER                   = "admin"
          GF_DATABASE_TYPE                         = "postgres"
          GF_DATABASE_HOST                         = local.grafana_db_host # postgres.tf: the Patroni VIP after the cutover
          GF_DATABASE_NAME                         = "grafana"
          GF_DATABASE_USER                         = "grafana"
          GF_UNIFIED_ALERTING_HA_LISTEN_ADDRESS    = "0.0.0.0:9094"
          GF_UNIFIED_ALERTING_HA_ADVERTISE_ADDRESS = "${local.grafana_gossip[name]}:9094"
          GF_UNIFIED_ALERTING_HA_PEERS             = local.grafana_peers
          GF_METRICS_ENABLED                       = "true"
          GF_ANALYTICS_REPORTING_ENABLED           = "false"
          GF_ANALYTICS_CHECK_FOR_UPDATES           = "false"
          }, local.grafana_db_env, local.home_dashboard_path == null ? {} : {
          GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH = local.home_dashboard_path
        })
        env_files   = ["${local.grafana_conf}/grafana.env"]
        exec        = []
        user        = null
        caps        = []
        podman_args = []
        # Grafana 13's file provisioner doesn't always pick up new dashboard folders by
        # polling, so dashboard changes ask it to rescan through the admin API.
        reload = "/usr/bin/podman exec grafana sh -c 'curl -fsS -X POST -u \"$$GF_SECURITY_ADMIN_USER:$$GF_SECURITY_ADMIN_PASSWORD\" http://127.0.0.1:3000/api/admin/provisioning/dashboards/reload'"
      })
      node-exporter = templatefile("${path.module}/templates/container.tftpl", {
        name        = "node-exporter"
        description = "Prometheus node exporter"
        image       = var.images.node_exporter
        network     = "host"
        publish     = []
        volumes     = local.node_exporter_volumes
        env         = {}
        env_files   = []
        # address-info: node_network_address_info shows which VM holds the Grafana VIP.
        exec        = concat(["--path.rootfs=/host", "--web.listen-address=${g.backend_address}:9100", "--collector.netdev.address-info"], local.node_exporter_collectors)
        user        = null
        caps        = []
        podman_args = ["--pid=host"]
        reload      = false
      })
    }
  }

  grafana_deployments = {
    for name, g in var.grafana : name => templatefile("${path.module}/templates/deploy.sh.tftpl", {
      host       = name
      state_file = "${local.grafana_conf}/.tofu-quadlets"
      images     = [var.images.grafana, var.images.node_exporter, var.images.alloy]
      packages   = local.grafana_ha_packages
      apt        = null
      dirs = concat(local.alloy_dirs, local.grafana_ha_dirs, [
        { path = local.quadlet_dir, mode = "0755", owner = "root" },
        { path = local.grafana_conf, mode = "0755", owner = "root" },
        { path = "${local.grafana_conf}/provisioning", mode = "0755", owner = "root" },
        { path = "${local.grafana_conf}/provisioning/datasources", mode = "0755", owner = "root" },
        { path = "${local.grafana_conf}/provisioning/dashboards", mode = "0755", owner = "root" },
        { path = local.dashboards_dir, mode = "0755", owner = "root" },
        { path = local.grafana_data, mode = "0750", owner = "runtime|${var.images.grafana}" },
        ], [
        for dir in local.dashboard_dirs : { path = "${local.dashboards_dir}/${dir}", mode = "0755", owner = "root" }
      ])
      # Dashboard JSON that's no longer in the module is deleted, and Grafana drops the dashboard.
      prune_dirs = [local.dashboards_dir]
      files = concat(
        [for unit in ["grafana", "node-exporter"] : {
          path    = "${local.quadlet_dir}/${unit}.container"
          mode    = "0644"
          owner   = "root"
          content = local.grafana_units[name][unit]
          restart = [unit]
          reload  = []
        }],
        [
          {
            path    = "${local.grafana_conf}/provisioning/datasources/datasources.yml"
            mode    = "0644"
            owner   = "root"
            content = local.datasources_yml
            restart = ["grafana"]
            reload  = []
          },
          {
            path    = "${local.grafana_conf}/provisioning/dashboards/dashboards.yml"
            mode    = "0644"
            owner   = "root"
            content = local.dashboard_providers_yml
            restart = ["grafana"]
            reload  = []
          },
          {
            path    = "${local.grafana_conf}/grafana.env"
            mode    = "0600"
            owner   = "root"
            content = "GF_SECURITY_ADMIN_PASSWORD=${var.secrets.grafana_admin_password}\nGF_SECURITY_SECRET_KEY=${var.secrets.grafana_secret_key}\nGF_DATABASE_PASSWORD=${var.secrets.grafana_db_password}\nINFLUXDB_TOKEN=${var.secrets.influxdb_admin_token}\n${join("", [for app in local.pg_grafana_apps : "PG_APP_${upper(app)}_GRAFANA_PASSWORD=${var.postgres_app_passwords["${app}_grafana"]}\n"])}"
            restart = ["grafana"]
            reload  = []
          },
        ],
        # No restart: the provider polls the directory (updateIntervalSeconds), and a
        # reload (ExecReload above) makes it rescan right away, new folders included.
        [for rel, content in local.dashboards : {
          path    = "${local.dashboards_dir}/${rel}"
          mode    = "0644"
          owner   = "root"
          content = content
          restart = []
          reload  = ["grafana"]
        }],
        local.alloy_files[name],      # logging.tf
        local.grafana_ha_files[name], # grafana-ha.tf
      )
      validations  = concat([local.alloy_validation[name]], local.grafana_ha_validations)
      post_install = local.grafana_ha_post_install
      services     = concat(["grafana", "node-exporter", "alloy"], local.grafana_ha_services)
      health       = ["curl -fsS -o /dev/null --max-time 3 http://127.0.0.1:3000/api/health", local.alloy_health[name]]
    })
  }
}
