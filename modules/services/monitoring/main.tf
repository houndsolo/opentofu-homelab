locals {
  backend_conf = "/etc/monitoring"
  backend_data = "/var/lib/monitoring"
  grafana_conf = "/etc/grafana-container"
  grafana_data = "/var/lib/grafana-container"
  quadlet_dir  = "/etc/containers/systemd"

  mon  = var.backend.monitoring_address
  back = var.backend.backend_address

  # Whether a token was given is not secret; the token itself stays sensitive.
  pve_enabled = nonsensitive(var.pve_exporter_token != null)
  # Same for whether SNMPv3 auths were given.
  snmp_auths_enabled = nonsensitive(length(var.snmp_auths) > 0)
  snmp_auths_path    = "${local.backend_conf}/snmp-exporter/auths.yml"
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
      { job_name = "prometheus", static_configs = [{ targets = ["localhost:9090"] }] },
      { job_name = "alertmanager", static_configs = [{ targets = ["alertmanager:9093"] }] },
      { job_name = "snmp-exporter", static_configs = [{ targets = ["snmp-exporter:9116"] }] },
      { job_name = "blackbox-exporter", static_configs = [{ targets = ["blackbox-exporter:9115"] }] },
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
    [for name, job in var.targets.snmp : {
      job_name        = "snmp-${name}"
      metrics_path    = "/snmp"
      params          = { module = job.modules, auth = [job.auth] }
      static_configs  = [for host, address in job.targets : { targets = [address], labels = { host = host } }]
      relabel_configs = local.proxy_relabel.snmp
    }],
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
  )

  prometheus_yml = yamlencode({
    global = {
      scrape_interval     = "30s"
      evaluation_interval = "30s"
      external_labels     = { site = "lylat" }
    }
    alerting       = { alertmanagers = [{ static_configs = [{ targets = ["alertmanager:9093"] }] }] }
    rule_files     = ["/etc/prometheus/rules/*.yml"]
    scrape_configs = local.scrape_configs
  })

  rules_yml = yamlencode({
    groups = [{
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
    }]
  })

  # Placeholder routing: alerts are visible in Alertmanager/Grafana but not sent anywhere yet.
  alertmanager_yml = yamlencode({
    route = {
      receiver        = "null"
      group_by        = ["alertname", "job"]
      group_wait      = "30s"
      group_interval  = "5m"
      repeat_interval = "4h"
    }
    receivers = [{ name = "null" }]
  })

  blackbox_yml = yamlencode({
    modules = {
      icmp     = { prober = "icmp", timeout = "5s", icmp = { preferred_ip_protocol = "ip4" } }
      http_2xx = { prober = "http", timeout = "5s", http = { preferred_ip_protocol = "ip4" } }
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
    datasources = [
      {
        name      = "Prometheus"
        uid       = "prometheus"
        type      = "prometheus"
        access    = "proxy"
        url       = "http://${local.back}:9090"
        isDefault = true
        jsonData  = { timeInterval = "30s" }
      },
      {
        name     = "Alertmanager"
        uid      = "alertmanager"
        type     = "alertmanager"
        access   = "proxy"
        url      = "http://${local.back}:9093"
        jsonData = { implementation = "prometheus" }
      },
      {
        name           = "InfluxDB"
        uid            = "influxdb"
        type           = "influxdb"
        access         = "proxy"
        url            = "http://${local.back}:8086"
        jsonData       = { version = "Flux", organization = var.settings.influxdb_org, defaultBucket = var.settings.influxdb_grafana_bucket }
        secureJsonData = { token = "$INFLUXDB_TOKEN" } # Expanded by Grafana from grafana.env.
      },
    ]
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

  # One container unit per service. "reload" adds ExecReload (SIGHUP) for config-only changes.
  # A {for} expression keeps the per-service object shapes (merge with a
  # conditional {} would need identical types).
  backend_containers = {
    for name, c in local.backend_container_defs : name => c
    if name != "pve-exporter" || local.pve_enabled
  }
  backend_container_defs = {
    prometheus = {
      description = "Prometheus"
      image       = var.images.prometheus
      publish     = ["${local.mon}:9090:9090", "${local.back}:9090:9090"]
      volumes     = ["${local.backend_conf}/prometheus:/etc/prometheus:ro", "${local.backend_data}/prometheus:/prometheus"]
      exec = [
        "--config.file=/etc/prometheus/prometheus.yml",
        "--storage.tsdb.path=/prometheus",
        "--storage.tsdb.retention.time=${var.settings.prometheus_retention_time}",
        "--storage.tsdb.retention.size=${var.settings.prometheus_retention_size}",
        "--web.external-url=http://${local.mon}:9090/",
        "--web.enable-lifecycle",
      ]
      reload = true
    }
    alertmanager = {
      description = "Prometheus Alertmanager"
      image       = var.images.alertmanager
      publish     = ["${local.mon}:9093:9093", "${local.back}:9093:9093"]
      volumes     = ["${local.backend_conf}/alertmanager:/etc/alertmanager:ro", "${local.backend_data}/alertmanager:/alertmanager"]
      exec = [
        "--config.file=/etc/alertmanager/alertmanager.yml",
        "--storage.path=/alertmanager",
        "--web.external-url=http://${local.mon}:9093/",
        "--cluster.listen-address=", # Single instance: no gossip listener.
      ]
      reload = true
    }
    snmp-exporter = {
      description = "Prometheus SNMP exporter (bundled snmp.yml, plus SNMPv3 auths when given)"
      image       = var.images.snmp_exporter
      volumes     = local.snmp_auths_enabled ? ["${local.snmp_auths_path}:/etc/snmp_exporter/auths.yml:ro"] : []
      exec        = local.snmp_auths_enabled ? ["--config.file=/etc/snmp_exporter/snmp.yml", "--config.file=/etc/snmp_exporter/auths.yml"] : []
    }
    blackbox-exporter = {
      description = "Prometheus blackbox exporter"
      image       = var.images.blackbox_exporter
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
      publish     = ["${local.mon}:8086:8086", "${local.back}:8086:8086"]
      volumes     = ["${local.backend_data}/influxdb/data:/var/lib/influxdb2", "${local.backend_data}/influxdb/config:/etc/influxdb2"]
      env = {
        DOCKER_INFLUXDB_INIT_MODE      = "setup"
        DOCKER_INFLUXDB_INIT_USERNAME  = "admin"
        DOCKER_INFLUXDB_INIT_ORG       = var.settings.influxdb_org
        DOCKER_INFLUXDB_INIT_BUCKET    = var.settings.influxdb_bucket
        DOCKER_INFLUXDB_INIT_RETENTION = var.settings.influxdb_retention
      }
      env_files = ["${local.backend_conf}/influxdb.env"]
    }
    postgres = {
      description = "PostgreSQL for the shared Grafana database"
      image       = var.images.postgres
      publish     = ["${local.back}:5432:5432"]
      volumes     = ["${local.backend_data}/postgres:/var/lib/postgresql/data"]
      env         = { POSTGRES_USER = "grafana", POSTGRES_DB = "grafana" }
      env_files   = ["${local.backend_conf}/postgres.env"]
    }
    node-exporter = {
      description = "Prometheus node exporter"
      image       = var.images.node_exporter
      network     = "host"
      volumes     = ["/:/host:ro,rslave"]
      podman_args = ["--pid=host"]
      exec        = ["--path.rootfs=/host", "--web.listen-address=${local.mon}:9100"]
    }
    pve-exporter = {
      description = "Prometheus Proxmox VE exporter"
      image       = var.images.pve_exporter
      volumes     = ["${local.backend_conf}/pve-exporter/pve.yml:/etc/prometheus/pve.yml:ro"]
    }
  }

  # Restart and health order on the backend.
  backend_order = [for name in ["postgres", "influxdb", "snmp-exporter", "blackbox-exporter", "pve-exporter", "alertmanager", "prometheus", "node-exporter"] : name if contains(keys(local.backend_containers), name)]

  backend_units = {
    for name, c in local.backend_containers : name => templatefile("${path.module}/templates/container.tftpl", {
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
    })
  }

  backend_files = concat(
    [{
      path    = "${local.quadlet_dir}/monitoring.network"
      mode    = "0644"
      owner   = "root"
      content = file("${path.module}/templates/monitoring.network")
      restart = ["monitoring-network"]
      reload  = []
    }],
    [for name in local.backend_order : {
      path    = "${local.quadlet_dir}/${name}.container"
      mode    = "0644"
      owner   = "root"
      content = local.backend_units[name]
      restart = [name]
      reload  = []
    }],
    [
      { path = "${local.backend_conf}/prometheus/prometheus.yml", mode = "0644", owner = "root", content = local.prometheus_yml, restart = [], reload = ["prometheus"] },
      { path = "${local.backend_conf}/prometheus/rules/basic.yml", mode = "0644", owner = "root", content = local.rules_yml, restart = [], reload = ["prometheus"] },
      { path = "${local.backend_conf}/alertmanager/alertmanager.yml", mode = "0644", owner = "root", content = local.alertmanager_yml, restart = [], reload = ["alertmanager"] },
      { path = "${local.backend_conf}/blackbox/config.yml", mode = "0644", owner = "root", content = local.blackbox_yml, restart = [], reload = ["blackbox-exporter"] },
      {
        path    = "${local.backend_conf}/influxdb.env"
        mode    = "0600"
        owner   = "root"
        content = "DOCKER_INFLUXDB_INIT_PASSWORD=${var.secrets.influxdb_admin_password}\nDOCKER_INFLUXDB_INIT_ADMIN_TOKEN=${var.secrets.influxdb_admin_token}\n"
        restart = ["influxdb"]
        reload  = []
      },
      {
        path    = "${local.backend_conf}/postgres.env"
        mode    = "0600"
        owner   = "root"
        content = "POSTGRES_PASSWORD=${var.secrets.grafana_db_password}\n"
        restart = ["postgres"]
        reload  = []
      },
    ],
    local.pve_enabled ? [{
      # Readable by the exporter's runtime user only.
      path    = "${local.backend_conf}/pve-exporter/pve.yml"
      mode    = "0640"
      owner   = "runtime|${var.images.pve_exporter}"
      content = local.pve_yml
      restart = ["pve-exporter"]
      reload  = []
    }] : [],
    local.snmp_auths_enabled ? [{
      # SNMPv3 credentials; the exporter image runs as root.
      path    = local.snmp_auths_path
      mode    = "0600"
      owner   = "root"
      content = local.snmp_auths_yml
      restart = ["snmp-exporter"]
      reload  = []
    }] : [],
  )

  backend_dirs = concat(
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
      { path = "${local.backend_data}/postgres", mode = "0700", owner = "user|${var.images.postgres}|postgres" },
    ],
    local.pve_enabled ? [{ path = "${local.backend_conf}/pve-exporter", mode = "0755", owner = "root" }] : [],
    local.snmp_auths_enabled ? [{ path = "${local.backend_conf}/snmp-exporter", mode = "0755", owner = "root" }] : [],
  )

  backend_validations = concat([
    "podman run --rm --network=none --user 0 --entrypoint promtool -v \"$root${local.backend_conf}/prometheus:/etc/prometheus:ro\" '${var.images.prometheus}' check config /etc/prometheus/prometheus.yml",
    "podman run --rm --network=none --user 0 --entrypoint amtool -v \"$root${local.backend_conf}/alertmanager:/etc/alertmanager:ro\" '${var.images.alertmanager}' check-config /etc/alertmanager/alertmanager.yml",
    "podman run --rm --network=none --user 0 -v \"$root${local.backend_conf}/blackbox:/etc/blackbox_exporter:ro\" '${var.images.blackbox_exporter}' --config.check --config.file=/etc/blackbox_exporter/config.yml",
    ], local.snmp_auths_enabled ? [
    "podman run --rm --network=none -v \"$root${local.snmp_auths_path}:/etc/snmp_exporter/auths.yml:ro\" '${var.images.snmp_exporter}' --dry-run --config.file=/etc/snmp_exporter/snmp.yml --config.file=/etc/snmp_exporter/auths.yml",
  ] : [])

  backend_health = [
    "curl -fsS -o /dev/null --max-time 3 http://${local.back}:9090/-/ready",
    "curl -fsS -o /dev/null --max-time 3 http://${local.back}:9093/-/ready",
    "curl -fsS -o /dev/null --max-time 3 http://${local.back}:8086/health",
    "podman exec postgres pg_isready -q -U grafana -d grafana",
  ]

  backend_deployment = templatefile("${path.module}/templates/deploy.sh.tftpl", {
    host        = var.backend.name
    state_file  = "${local.backend_conf}/.tofu-quadlets"
    images      = distinct([for c in values(local.backend_containers) : c.image])
    dirs        = local.backend_dirs
    prune_dirs  = []
    files       = local.backend_files
    validations = local.backend_validations
    services    = concat(["monitoring-network"], local.backend_order)
    health      = local.backend_health
  })

  # Grafana front ends.
  grafana_peers = join(",", [for name in sort(keys(var.grafana)) : "${var.grafana[name].backend_address}:9094"])

  # Quadlet units per Grafana VM (no secrets; those live in grafana.env).
  grafana_units = {
    for name, g in var.grafana : name => {
      grafana = templatefile("${path.module}/templates/container.tftpl", {
        name        = "grafana"
        description = "Grafana"
        image       = var.images.grafana
        network     = null # Default podman bridge; reaches the backend through the host.
        # UI on every address, so a future keepalived VIP works wherever it lands.
        publish = ["3000:3000", "${g.backend_address}:9094:9094/tcp", "${g.backend_address}:9094:9094/udp"]
        volumes = ["${local.grafana_conf}/provisioning:/etc/grafana/provisioning:ro", "${local.grafana_data}:/var/lib/grafana"]
        env = merge({
          GF_SERVER_ROOT_URL                       = var.settings.grafana_root_url
          GF_SECURITY_ADMIN_USER                   = "admin"
          GF_DATABASE_TYPE                         = "postgres"
          GF_DATABASE_HOST                         = "${local.back}:5432"
          GF_DATABASE_NAME                         = "grafana"
          GF_DATABASE_USER                         = "grafana"
          GF_UNIFIED_ALERTING_HA_LISTEN_ADDRESS    = "0.0.0.0:9094"
          GF_UNIFIED_ALERTING_HA_ADVERTISE_ADDRESS = "${g.backend_address}:9094"
          GF_UNIFIED_ALERTING_HA_PEERS             = local.grafana_peers
          GF_METRICS_ENABLED                       = "true"
          GF_ANALYTICS_REPORTING_ENABLED           = "false"
          GF_ANALYTICS_CHECK_FOR_UPDATES           = "false"
          }, local.home_dashboard_path == null ? {} : {
          GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH = local.home_dashboard_path
        })
        env_files   = ["${local.grafana_conf}/grafana.env"]
        exec        = []
        user        = null
        caps        = []
        podman_args = []
        reload      = false
      })
      node-exporter = templatefile("${path.module}/templates/container.tftpl", {
        name        = "node-exporter"
        description = "Prometheus node exporter"
        image       = var.images.node_exporter
        network     = "host"
        publish     = []
        volumes     = ["/:/host:ro,rslave"]
        env         = {}
        env_files   = []
        exec        = ["--path.rootfs=/host", "--web.listen-address=${g.backend_address}:9100"]
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
      images     = [var.images.grafana, var.images.node_exporter]
      dirs = concat([
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
            content = "GF_SECURITY_ADMIN_PASSWORD=${var.secrets.grafana_admin_password}\nGF_SECURITY_SECRET_KEY=${var.secrets.grafana_secret_key}\nGF_DATABASE_PASSWORD=${var.secrets.grafana_db_password}\nINFLUXDB_TOKEN=${var.secrets.influxdb_admin_token}\n"
            restart = ["grafana"]
            reload  = []
          },
        ],
        # No restart: the provider polls the directory (updateIntervalSeconds).
        [for rel, content in local.dashboards : {
          path    = "${local.dashboards_dir}/${rel}"
          mode    = "0644"
          owner   = "root"
          content = content
          restart = []
          reload  = []
        }],
      )
      validations = []
      services    = ["grafana", "node-exporter"]
      health      = ["curl -fsS -o /dev/null --max-time 3 http://127.0.0.1:3000/api/health"]
    })
  }
}
