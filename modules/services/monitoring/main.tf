locals {
  backend_conf = "/etc/monitoring"
  backend_data = "/var/lib/monitoring"
  grafana_conf = "/etc/grafana-container"
  grafana_data = "/var/lib/grafana-container"
  quadlet_dir  = "/etc/containers/systemd"

  # Backends (backends.tf has the HA pieces). mon/back are the primary's addresses, for
  # anything that has to name one backend (Grafana's datasources without a VIP or Mimir).
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

  # node_exporter on every VM here (backends, Grafana, logging.tf, metrics.tf, postgres.tf): its volumes and
  # collector flags are in templates/node-exporter.container.tftpl (services-config's template has the same
  # flags). Besides the defaults: the collectors Node Exporter Full graphs that are off by default
  # (processes, tcpstat, interrupts) and systemd, which asks systemd over the host's D-Bus system socket
  # (--path.rootfs doesn't cover that, hence the socket at the path D-Bus clients default to). The default
  # exclude already drops mounts, devices, slices and scopes; unit-include also leaves out targets and
  # paths (~55 units x 5 state series per VM). [.] instead of \. keeps the Quadlet Exec line free of escapes.

  # Deploy-time check of a staged keepalived.conf ($stage mirrors / in the deploy script, modules/services/quadlet-deploy),
  # the same on every role that runs keepalived. Skipped on the first deploy, before the package is installed.
  keepalived_validation = "if command -v keepalived >/dev/null; then keepalived -t -f \"$stage/etc/keepalived/keepalived.conf\"; else echo \"keepalived not installed yet: config test skipped\"; fi"

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
    # Telegraf on VyOS (firewall rule counters, interfaces, services, conntrack...).
    # Its metrics already carry host=<router>, the same as the target label.
    length(var.targets.telegraf) == 0 ? [] : [{
      job_name       = "vyos-telegraf"
      honor_labels   = true
      static_configs = [for t in var.targets.telegraf : { targets = ["${t.address}:9273"], labels = { host = t.host, role = "router" } }]
      # The syslog input carries each log message as a label (one new series per
      # line); the router logs are read from Loki instead.
      metric_relabel_configs = [{ source_labels = ["__name__"], regex = "syslog_.*", action = "drop" }]
    }],
    # Only the active mgr serves metrics; standbys answer with an empty 200. Every
    # mgr host is listed so a failover needs no config change. The mgr's own
    # instance labels (OSD hostnames on ceph_disk_occupation etc.) are kept, and
    # the rest get instance="ceph_cluster" with no host label, so series don't
    # change identity when the active mgr moves. up{job="ceph"} keeps per-host labels.
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
    # Slow agents (the MikroTiks' SNMP walk takes several seconds) get their own interval/timeout.
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
    local.pvestatd_scrape_configs, # pvestatd.tf
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
      scrape_configs = local.scrape_configs_host_instance
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
    }], local.storage_health_rules, local.infra_rules, local.logging_rules, local.wlc_rules, local.pvestatd_rules, local.mimir_rules, local.backend_rules, local.postgres_rules, local.rgw_rules, local.valkey_rules, local.nginx_rules, local.bind_rules) # infra-alerts.tf, logging.tf, telemetry.tf, pvestatd.tf, metrics.tf, backends.tf, postgres.tf, rgw.tf, valkey.tf, nginx.tf, bind.tf
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
  # selectors get host=~ the PVE cluster's nodes (targets.pve; standalone PVE hosts aren't in Ceph),
  # because node_exporter runs on every host here, not just on the Ceph nodes (unfiltered,
  # CephNodeInconsistentMTU fires for each VyOS interface whose MTU differs from the
  # median of all hosts' same-named interfaces, CephNodeDiskspaceWarning for any VM).
  ceph_alerts_enabled = length(var.targets.ceph) > 0
  ceph_node_sel       = length(var.targets.pve) == 0 ? "" : "host=~\"${join("|", sort([for t in var.targets.pve : t.host]))}\""
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

  # Quadlet units per backend (templates/<name>.container.tftpl). Telegraf (WLC telemetry) where
  # wlc_telemetry.backends lists the backend, pvestatd and pve-exporter when they're on.
  backend_units = {
    for host, b in var.backends : host => { for name, unit in {
      telegraf = local.wlc_unit[host]      # telemetry.tf
      pvestatd = local.pvestatd_unit[host] # pvestatd.tf
      snmp-exporter = templatefile("${path.module}/templates/snmp-exporter.container.tftpl", {
        image           = var.images.snmp_exporter
        backend_address = b.backend_address
        volumes         = local.snmp_volumes
        config_files    = local.snmp_config_files
      })
      blackbox-exporter = templatefile("${path.module}/templates/blackbox-exporter.container.tftpl", {
        image           = var.images.blackbox_exporter
        backend_address = b.backend_address
      })
      pve-exporter = local.pve_enabled ? templatefile("${path.module}/templates/pve-exporter.container.tftpl", { image = var.images.pve_exporter }) : null
      alertmanager = templatefile("${path.module}/templates/alertmanager.container.tftpl", {
        image              = var.images.alertmanager
        monitoring_address = b.monitoring_address
        backend_address    = b.backend_address
        vips               = local.backend_vip_backend # Grafana's Alertmanager datasource (backends.tf)
        gossip_address     = local.am_cluster_enabled ? local.am_gossip[host] : null
        peers              = [for peer in local.backend_names : local.am_gossip[peer] if peer != host]
      })
      prometheus = templatefile("${path.module}/templates/prometheus.container.tftpl", {
        image              = var.images.prometheus
        monitoring_address = b.monitoring_address
        backend_address    = b.backend_address
        retention_time     = var.settings.prometheus_retention_time
        retention_size     = var.settings.prometheus_retention_size
      })
      # address-info: node_network_address_info shows which backend holds each VIP.
      node-exporter = templatefile("${path.module}/templates/node-exporter.container.tftpl", {
        image          = var.images.node_exporter
        listen_address = coalesce(b.telemetry_address, b.monitoring_address)
        textfile_dir   = null
      })
    } : name => unit if unit != null }
  }

  # Start order on each backend.
  backend_order = {
    for host in local.backend_names : host => [
      for name in ["telegraf", "pvestatd", "snmp-exporter", "blackbox-exporter", "pve-exporter", "alertmanager", "prometheus", "node-exporter"] : name
      if contains(keys(local.backend_units[host]), name)
    ]
  }

  # Files per backend for modules/services/quadlet-deploy: a changed unit file restarts its unit, any other
  # changed file reloads its units (restart = true: restarts them).
  backend_files = {
    for host in local.backend_names : host => concat(
      [{ path = "${local.quadlet_dir}/monitoring.network", content = file("${path.module}/templates/monitoring.network"), units = ["monitoring-network"] }],
      [for name in local.backend_order[host] : { path = "${local.quadlet_dir}/${name}.container", content = local.backend_units[host][name], units = [name] }],
      [
        { path = "${local.backend_conf}/prometheus/prometheus.yml", content = local.prometheus_yml[host], units = ["prometheus"] },
        { path = "${local.backend_conf}/prometheus/rules/basic.yml", content = local.rules_yml, units = ["prometheus"] },
        { path = "${local.backend_conf}/alertmanager/alertmanager.yml", content = local.alertmanager_yml, units = ["alertmanager"] },
        { path = "${local.backend_conf}/blackbox/config.yml", content = local.blackbox_yml, units = ["blackbox-exporter"] },
      ],
      local.ceph_alerts_enabled ? [
        { path = "${local.backend_conf}/prometheus/rules/ceph.yml", content = local.ceph_alerts_yml, units = ["prometheus"] },
      ] : [],
      # Readable by the exporter's runtime user only (uid 101 in the image).
      local.pve_enabled ? [
        { path = "${local.backend_conf}/pve-exporter/pve.yml", mode = "0640", owner = "101:101", content = local.pve_yml, units = ["pve-exporter"], restart = true },
      ] : [],
      local.alloy_files[host], # logging.tf
      [for f, content in local.snmp_module_files : { path = "${local.snmp_conf}/${f}", content = content, units = ["snmp-exporter"], restart = true }],
      # SNMPv3 credentials; the exporter image runs as root.
      local.snmp_auths_enabled ? [
        { path = local.snmp_auths_path, mode = "0600", content = local.snmp_auths_yml, units = ["snmp-exporter"], restart = true },
      ] : [],
      local.wlc_files[host],        # telemetry.tf
      local.pvestatd_files[host],   # pvestatd.tf
      local.backend_ha_files[host], # backends.tf
    )
  }

  # Data directories are owned by the user each image runs as (Prometheus and Alertmanager: nobody).
  backend_dirs = {
    for host in local.backend_names : host => concat(
      [
        { path = "${local.backend_data}/prometheus", mode = "0750", owner = "65534:65534" },
        { path = "${local.backend_data}/alertmanager", mode = "0750", owner = "65534:65534" },
      ],
      local.alloy_dirs, # logging.tf
    )
  }

  # Validate the staged configs ($stage mirrors /) in throwaway containers without network.
  backend_checks = {
    for host in local.backend_names : host => concat([
      "podman run --rm --network=none --user 0 --entrypoint promtool -v \"$stage${local.backend_conf}/prometheus:/etc/prometheus:ro\" '${var.images.prometheus}' check config /etc/prometheus/prometheus.yml",
      ], local.ceph_alerts_enabled ? [
      # check config covers rules/*.yml too; this names the vendored file if it's the one that breaks.
      "podman run --rm --network=none --user 0 --entrypoint promtool -v \"$stage${local.backend_conf}/prometheus:/etc/prometheus:ro\" '${var.images.prometheus}' check rules /etc/prometheus/rules/ceph.yml",
      ] : [], [
      "podman run --rm --network=none --user 0 --entrypoint amtool -v \"$stage${local.backend_conf}/alertmanager:/etc/alertmanager:ro\" '${var.images.alertmanager}' check-config /etc/alertmanager/alertmanager.yml",
      "podman run --rm --network=none --user 0 -v \"$stage${local.backend_conf}/blackbox:/etc/blackbox_exporter:ro\" '${var.images.blackbox_exporter}' --config.check --config.file=/etc/blackbox_exporter/config.yml",
      local.alloy_check[host],
      # Loads the bundled snmp.yml with our modules (and auths) exactly as the container does.
      "podman run --rm --network=none ${join(" ", [for v in local.snmp_volumes : "-v \"$stage${v}\""])} '${var.images.snmp_exporter}' --dry-run ${join(" ", [for f in local.snmp_config_files : "--config.file=${f}"])}",
    ], local.wlc_checks[host], local.pvestatd_checks[host], local.backend_ha_checks) # telemetry.tf, pvestatd.tf, backends.tf
  }

  backend_services = {
    for host in local.backend_names : host => concat(["monitoring-network"], local.backend_order[host], ["alloy"], local.backend_ha_services)
  }

  backend_images = {
    for host in local.backend_names : host => distinct(concat(
      [var.images.prometheus, var.images.alertmanager, var.images.snmp_exporter, var.images.blackbox_exporter, var.images.node_exporter, var.images.alloy],
      local.pve_enabled ? [var.images.pve_exporter] : [],
      contains(local.wlc_backends, host) || local.pvestatd_enabled ? [var.images.telegraf] : [],
    ))
  }

  # Grafana front ends.
  # Alerting HA gossip: over the HA VLAN when every VM has an address there (grafana-ha.tf).
  grafana_peers = join(",", sort([for name in sort(keys(var.grafana)) : "${local.grafana_gossip[name]}:9094"]))

  # Quadlet units per Grafana VM (no secrets; those live in grafana.env).
  grafana_units = {
    for name, g in var.grafana : name => {
      grafana = templatefile("${path.module}/templates/grafana.container.tftpl", {
        image               = var.images.grafana
        gossip_address      = local.grafana_gossip[name]
        gossip_peers        = local.grafana_peers
        db_host             = local.grafana_db_host # postgres.tf: the Patroni VIP
        root_url            = var.settings.grafana_root_url
        home_dashboard_path = local.home_dashboard_path
      })
      # address-info: node_network_address_info shows which VM holds the Grafana VIP.
      node-exporter = templatefile("${path.module}/templates/node-exporter.container.tftpl", {
        image          = var.images.node_exporter
        listen_address = coalesce(g.telemetry_address, g.backend_address)
        textfile_dir   = null
      })
    }
  }

  grafana_files = {
    for name in local.grafana_names : name => concat(
      [for unit in ["grafana", "node-exporter"] : { path = "${local.quadlet_dir}/${unit}.container", content = local.grafana_units[name][unit], units = [unit] }],
      [
        { path = "${local.grafana_conf}/provisioning/datasources/datasources.yml", content = local.datasources_yml, units = ["grafana"], restart = true },
        { path = "${local.grafana_conf}/provisioning/dashboards/dashboards.yml", content = local.dashboard_providers_yml, units = ["grafana"], restart = true },
        {
          path    = "${local.grafana_conf}/grafana.env"
          mode    = "0600"
          content = "GF_SECURITY_ADMIN_PASSWORD=${var.secrets.grafana_admin_password}\nGF_SECURITY_SECRET_KEY=${var.secrets.grafana_secret_key}\nGF_DATABASE_PASSWORD=${var.secrets.grafana_db_password}\n${join("", [for app in local.pg_grafana_apps : "PG_APP_${upper(app)}_GRAFANA_PASSWORD=${var.postgres_app_passwords["${app}_grafana"]}\n"])}"
          units   = ["grafana"]
          restart = true
        },
      ],
      # Reload, no restart: ExecReload makes Grafana rescan the directory (new folders included).
      [for rel, content in local.dashboards : { path = "${local.dashboards_dir}/${rel}", content = content, units = ["grafana"] }],
      local.alloy_files[name],      # logging.tf
      local.grafana_ha_files[name], # grafana-ha.tf
    )
  }
}

# One deploy script per VM (modules/services/quadlet-deploy), run by the root's terraform_data resources.
module "backend_deploy" {
  source   = "../quadlet-deploy"
  for_each = var.backends

  name         = "monitoring"
  host         = each.key
  images       = local.backend_images[each.key]
  packages     = local.backend_ha_packages
  dirs         = local.backend_dirs[each.key]
  files        = local.backend_files[each.key]
  checks       = local.backend_checks[each.key]
  post_install = local.backend_ha_post_install # backends.tf
  units        = local.backend_services[each.key]
  # Prometheus, Alertmanager and the Telegrafs check themselves (HealthCmd in their units).
  verify = [local.alloy_verify[each.key]]
}

module "grafana_deploy" {
  source   = "../quadlet-deploy"
  for_each = var.grafana

  name     = "grafana"
  host     = each.key
  images   = [var.images.grafana, var.images.node_exporter, var.images.alloy]
  packages = local.grafana_ha_packages
  dirs     = concat(local.alloy_dirs, [{ path = local.grafana_data, mode = "0750", owner = "472:472" }]) # the grafana image's user
  # Dashboard JSON that's no longer in the module is deleted, and Grafana drops the dashboard.
  prune_dirs   = [local.dashboards_dir]
  files        = local.grafana_files[each.key]
  checks       = concat([local.alloy_check[each.key]], local.grafana_ha_checks)
  post_install = local.grafana_ha_post_install
  units        = concat(["grafana", "node-exporter", "alloy"], local.grafana_ha_services)
  # The unit's HealthCmd proves Grafana serves; /api/health also needs its database (the Patroni VIP).
  verify = ["retry curl -fsS -o /dev/null --max-time 3 http://127.0.0.1:3000/api/health", local.alloy_verify[each.key]]
}
