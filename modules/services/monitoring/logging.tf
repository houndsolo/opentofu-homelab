# Logging: Loki (monolithic, 3-instance ring), Alloy, haproxy (S3 to the Ceph RGWs on
# the PVE nodes), keepalived (VIPs) and node_exporter on every logging VM, plus Alloy
# (journal -> Loki) on the backend and Grafana VMs.

locals {
  logging_conf = "/etc/logging"
  logging_data = "/var/lib/logging"
  alloy_conf   = "/etc/alloy"
  alloy_data   = "/var/lib/alloy"

  logging_enabled = length(var.logging) > 0
  # Without secrets the files still render (with empty values), so the plan reaches the
  # root's precondition, which stops the deploy with a clear message.
  logging_secrets = var.logging_secrets != null ? var.logging_secrets : { s3_bucket = "", s3_access_key = "", s3_secret_key = "", vrrp_password = "" }
  logging_names   = sort(keys(var.logging))
  logging_vips    = var.logging_settings.vips
  vip_address     = { for net, cidr in local.logging_vips : net => split("/", cidr)[0] }
  # Grafana's datasource, Alloy pushes from the other VMs and the README all use the backend VIP.
  loki_url = "http://${local.vip_address.backend}:3100"

  # VRRP: priority by VM name order (150, 100, 50, ...). It only decides the first
  # election: every node is BACKUP with nopreempt, so the VIPs stay where they are until
  # their holder fails (FAULT) or stops.
  logging_priority = { for i, name in local.logging_names : name => max(150 - 50 * i, 10) }

  # Loki. One config per VM (instance address); the S3 keys come from loki.env
  # (-config.expand-env), so the YAML itself carries no secrets.
  loki_s3_bucket = local.logging_enabled ? nonsensitive(local.logging_secrets.s3_bucket) : ""
  loki_yml = {
    for name, vm in var.logging : name => yamlencode({
      target       = "all"
      auth_enabled = false
      server = {
        # Every address, so the backend VIP works wherever it is; logging-guard (nftables)
        # limits 3100 to loopback and the backend VLAN, 9095/7946 to the logging VMs' HA addresses.
        http_listen_address = "0.0.0.0"
        http_listen_port    = 3100
        grpc_listen_address = "0.0.0.0"
        grpc_listen_port    = 9095
        log_level           = "info"
      }
      common = {
        instance_addr      = vm.ha_address # ring address: ingester gRPC stays on the HA VLAN
        path_prefix        = "/loki"
        replication_factor = var.logging_settings.replication_factor
        ring               = { kvstore = { store = "memberlist" } }
        storage = {
          s3 = {
            endpoint          = "127.0.0.1:7480" # local haproxy -> RGWs
            region            = "default"
            bucketnames       = local.loki_s3_bucket
            access_key_id     = "$${LOKI_S3_ACCESS_KEY}"
            secret_access_key = "$${LOKI_S3_SECRET_KEY}"
            insecure          = true
            s3forcepathstyle  = true
          }
        }
      }
      memberlist = {
        cluster_label               = "lylat-loki"
        bind_addr                   = [vm.ha_address]
        bind_port                   = 7946
        advertise_addr              = vm.ha_address
        advertise_port              = 7946
        join_members                = [for peer in local.logging_names : "${var.logging[peer].ha_address}:7946"]
        abort_if_cluster_join_fails = false
      }
      schema_config = {
        configs = [{
          from         = var.logging_settings.schema_start
          store        = "tsdb"
          object_store = "s3"
          schema       = "v13"
          index        = { prefix = "index_", period = "24h" }
        }]
      }
      ingester = {
        wal = { replay_memory_ceiling = "2GB" }
      }
      pattern_ingester = { enabled = true } # patterns in Grafana Logs Drilldown
      limits_config = {
        retention_period          = var.logging_settings.retention_period
        ingestion_rate_mb         = 16
        ingestion_burst_size_mb   = 32
        allow_structured_metadata = true
        volume_enabled            = true
      }
      # Every instance runs a compactor, but they elect one through the ring (a single
      # token), so only one compacts and applies retention. Delete requests live in S3.
      compactor = {
        working_directory      = "/loki/compactor"
        compaction_interval    = "10m"
        retention_enabled      = true
        retention_delete_delay = "2h"
        delete_request_store   = "s3"
      }
      # Rule groups are sharded over the ruler ring: each group is evaluated by one
      # instance, so an alert is sent once. Rules come from local files (same on every VM).
      ruler = {
        alertmanager_url = "http://${local.back}:9093" # the backend's Alertmanager, over the backend VLAN
        enable_api       = true
        enable_sharding  = true
        rule_path        = "/loki/rules-temp"
        wal              = { dir = "/loki/ruler-wal" }
        storage          = { type = "local", local = { directory = "/etc/loki/rules" } }
      }
      analytics = { reporting_enabled = false }
    })
  }

  # Ruler rules, tenant "fake" (auth_enabled: false).
  loki_rules_yml = yamlencode({
    groups = [{
      name = "logging"
      rules = [
        {
          alert       = "BGPSessionDownLogged"
          expr        = "sum by (host) (count_over_time({source=\"syslog\"} |= \"ADJCHANGE\" |~ \"(?i)down\" [5m])) > 0"
          labels      = { severity = "warning" }
          annotations = { summary = "{{ $labels.host }} logged a BGP session going down" }
        },
      ]
    }]
  })

  loki_env = local.logging_enabled ? "LOKI_S3_ACCESS_KEY=${local.logging_secrets.s3_access_key}\nLOKI_S3_SECRET_KEY=${local.logging_secrets.s3_secret_key}\n" : ""

  # Alloy everywhere: journal -> Loki; on the logging VMs also the syslog receiver,
  # pushing to the local Loki (which replicates to the others).
  alloy_hosts = merge(
    { (var.backend.name) = { listen = local.back, loki_url = local.loki_url, syslog = false } },
    { for name, g in var.grafana : name => { listen = g.backend_address, loki_url = local.loki_url, syslog = false } },
    { for name, vm in var.logging : name => { listen = vm.backend_address, loki_url = "http://127.0.0.1:3100", syslog = true } },
  )
  alloy_config = {
    for name, a in local.alloy_hosts : name => templatefile("${path.module}/templates/config.alloy.tftpl", {
      host        = name
      loki_url    = a.loki_url
      syslog      = a.syslog
      syslog_port = 514
      raw_port    = 1514
      # Senders' address => host label (wins over the hostname in the message, which is
      # missing in raw messages and generic on some switches).
      host_overrides = var.logging_settings.syslog_host_overrides
    })
  }
  alloy_unit = {
    for name, a in local.alloy_hosts : name => templatefile("${path.module}/templates/container.tftpl", {
      name        = "alloy"
      description = "Grafana Alloy (journal${a.syslog ? " and syslog" : ""} -> Loki)"
      image       = var.images.alloy
      network     = "host" # syslog senders' addresses, the VIPs, the journal
      publish     = []
      volumes = [
        "${local.alloy_conf}:/etc/alloy:ro",
        "${local.alloy_data}:/var/lib/alloy",
        "/var/log/journal:/var/log/journal:ro",
        "/run/log/journal:/run/log/journal:ro",
        "/etc/machine-id:/etc/machine-id:ro",
      ]
      env       = {}
      env_files = []
      exec = concat([
        "run", "/etc/alloy/config.alloy",
        "--storage.path=/var/lib/alloy/data",
        "--server.http.listen-addr=${a.listen}:12345",
        "--disable-reporting",
      ], local.alloy_stability[name])
      user        = null
      caps        = []
      podman_args = []
      reload      = true # SIGHUP reloads the config
    })
  }
  alloy_dirs = [
    { path = local.alloy_conf, mode = "0755", owner = "root" },
    { path = local.alloy_data, mode = "0750", owner = "runtime|${var.images.alloy}" },
  ]
  alloy_files = {
    for name in keys(local.alloy_hosts) : name => [
      { path = "${local.quadlet_dir}/alloy.container", mode = "0644", owner = "root", content = local.alloy_unit[name], restart = ["alloy"], reload = [] },
      { path = "${local.alloy_conf}/config.alloy", mode = "0644", owner = "root", content = local.alloy_config[name], restart = [], reload = ["alloy"] },
    ]
  }
  # The syslog receiver's raw listener (Cisco IOS-XE, FS S3910: not RFC 3164) is
  # experimental in Alloy; "alloy validate" doesn't check stability, "run" refuses it.
  alloy_stability = { for name, a in local.alloy_hosts : name => a.syslog ? ["--stability.level=experimental"] : [] }
  alloy_validation = {
    for name, a in local.alloy_hosts : name => join(" ", concat([
      "podman run --rm --network=none --user 0 -v \"$root${local.alloy_conf}:/etc/alloy:ro\" '${var.images.alloy}' validate",
    ], local.alloy_stability[name], ["/etc/alloy/config.alloy"]))
  }
  alloy_health = { for name, a in local.alloy_hosts : name => "curl -fsS -o /dev/null --max-time 3 http://${a.listen}:12345/-/ready" }

  # keepalived: one VRRP instance per network, unicast to the other logging VMs.
  keepalived_conf = {
    for name, vm in var.logging : name => templatefile("${path.module}/templates/keepalived.conf.tftpl", {
      host          = name
      router_id     = var.logging_settings.vrrp_router_id
      priority      = local.logging_priority[name]
      auth_pass     = local.logging_secrets.vrrp_password
      alloy_address = vm.backend_address
      ha_interface  = vm.interfaces.ha
      ha_address    = vm.ha_address
      peers         = [for peer in local.logging_names : var.logging[peer].ha_address if peer != name]
      vips          = [for net in ["backend", "monitoring", "mgmt"] : { cidr = local.logging_vips[net], interface = vm.interfaces[net] }]
    })
  }

  logging_units = {
    for name, vm in var.logging : name => {
      haproxy = templatefile("${path.module}/templates/container.tftpl", {
        name        = "haproxy"
        description = "haproxy: S3 on 127.0.0.1:7480 -> Ceph RGWs"
        image       = var.images.haproxy
        network     = "host"
        publish     = []
        volumes     = ["${local.logging_conf}/haproxy:/usr/local/etc/haproxy:ro"]
        env         = {}
        env_files   = []
        exec        = []
        user        = null
        caps        = []
        podman_args = []
        reload      = false
      })
      loki = templatefile("${path.module}/templates/container.tftpl", {
        name        = "loki"
        description = "Grafana Loki (monolithic, ring of ${length(var.logging)})"
        image       = var.images.loki
        network     = "host"
        publish     = []
        volumes     = ["${local.logging_conf}/loki:/etc/loki:ro", "${local.logging_data}/loki:/loki"]
        env         = {}
        env_files   = ["${local.logging_conf}/loki.env"]
        exec        = ["-config.file=/etc/loki/loki.yaml", "-config.expand-env=true"]
        user        = null
        caps        = []
        podman_args = []
        reload      = false
      })
      alloy = local.alloy_unit[name]
      node-exporter = templatefile("${path.module}/templates/container.tftpl", {
        name        = "node-exporter"
        description = "Prometheus node exporter"
        image       = var.images.node_exporter
        network     = "host"
        publish     = []
        volumes     = ["/:/host:ro,rslave"]
        env         = {}
        env_files   = []
        # address-info: node_network_address_info shows which VM holds each VIP.
        exec        = ["--path.rootfs=/host", "--web.listen-address=${vm.backend_address}:9100", "--collector.netdev.address-info"]
        user        = null
        caps        = []
        podman_args = ["--pid=host"]
        reload      = false
      })
    }
  }

  # Start order: the guard before Loki opens its ports, S3 before Loki, keepalived last.
  logging_services   = ["logging-guard", "haproxy", "loki", "alloy", "node-exporter", "keepalived"]
  logging_containers = ["haproxy", "loki", "alloy", "node-exporter"]

  logging_deployments = {
    for name, vm in var.logging : name => templatefile("${path.module}/templates/deploy.sh.tftpl", {
      host       = name
      state_file = "${local.logging_conf}/.tofu-quadlets"
      images     = [var.images.haproxy, var.images.loki, var.images.alloy, var.images.node_exporter]
      packages   = ["keepalived"]
      dirs = concat(
        [
          { path = local.quadlet_dir, mode = "0755", owner = "root" },
          { path = local.logging_conf, mode = "0755", owner = "root" },
          { path = "${local.logging_conf}/haproxy", mode = "0755", owner = "root" },
          { path = "${local.logging_conf}/loki", mode = "0755", owner = "root" },
          { path = "${local.logging_conf}/loki/rules", mode = "0755", owner = "root" },
          { path = "${local.logging_conf}/loki/rules/fake", mode = "0755", owner = "root" },
          { path = local.logging_data, mode = "0755", owner = "root" },
          { path = "${local.logging_data}/loki", mode = "0750", owner = "runtime|${var.images.loki}" },
          { path = "/etc/keepalived", mode = "0755", owner = "root" },
        ],
        local.alloy_dirs,
      )
      prune_dirs = ["${local.logging_conf}/loki/rules"]
      files = concat(
        [for unit in local.logging_containers : {
          path    = "${local.quadlet_dir}/${unit}.container"
          mode    = "0644"
          owner   = "root"
          content = local.logging_units[name][unit]
          restart = [unit]
          reload  = []
        }],
        [for f in local.alloy_files[name] : f if f.path != "${local.quadlet_dir}/alloy.container"],
        [
          { path = "${local.logging_conf}/haproxy/haproxy.cfg", mode = "0644", owner = "root", content = local.haproxy_cfg[name], restart = ["haproxy"], reload = [] },
          { path = "${local.logging_conf}/loki/loki.yaml", mode = "0644", owner = "root", content = local.loki_yml[name], restart = ["loki"], reload = [] },
          # The ruler polls the rules directory: no restart.
          { path = "${local.logging_conf}/loki/rules/fake/logging.yaml", mode = "0644", owner = "root", content = local.loki_rules_yml, restart = [], reload = [] },
          { path = "${local.logging_conf}/loki.env", mode = "0600", owner = "root", content = local.loki_env, restart = ["loki"], reload = [] },
          { path = "${local.logging_conf}/guard.nft", mode = "0644", owner = "root", content = local.guard_nft, restart = ["logging-guard"], reload = [] },
          { path = "/etc/systemd/system/logging-guard.service", mode = "0644", owner = "root", content = file("${path.module}/templates/logging-guard.service"), restart = ["logging-guard"], reload = [] },
          { path = "/etc/keepalived/keepalived.conf", mode = "0600", owner = "root", content = local.keepalived_conf[name], restart = [], reload = ["keepalived"] },
        ],
      )
      validations = [
        "podman run --rm --network=none --user 0 -v \"$root${local.logging_conf}/loki:/etc/loki:ro\" '${var.images.loki}' -config.file=/etc/loki/loki.yaml -config.expand-env=true -verify-config",
        local.alloy_validation[name],
        "podman run --rm --network=none --user 0 -v \"$root${local.logging_conf}/haproxy:/usr/local/etc/haproxy:ro\" '${var.images.haproxy}' haproxy -c -q -f /usr/local/etc/haproxy/haproxy.cfg",
        "nft -c -f \"$root${local.logging_conf}/guard.nft\"",
        "if command -v keepalived >/dev/null; then keepalived -t -f \"$root/etc/keepalived/keepalived.conf\"; else echo \"keepalived not installed yet: config test skipped\"; fi",
      ]
      post_install = ["systemctl enable --quiet logging-guard.service keepalived.service"]
      services     = local.logging_services
      health = [
        "curl -fsS -o /dev/null --max-time 3 http://127.0.0.1:7480/", # haproxy -> an RGW
        "curl -fsS -o /dev/null --max-time 3 http://127.0.0.1:3100/ready",
        local.alloy_health[name],
        "nft list table inet logging_guard",
      ]
    })
  }

  haproxy_cfg = {
    for name, vm in var.logging : name => templatefile("${path.module}/templates/haproxy.cfg.tftpl", {
      host          = name
      endpoints     = var.logging_settings.rgw_endpoints
      stats_address = vm.backend_address
    })
  }

  guard_nft = templatefile("${path.module}/templates/logging-guard.nft.tftpl", {
    sources      = var.logging_settings.loki_allowed_sources
    ring_sources = [for name in local.logging_names : var.logging[name].ha_address]
  })

  # Prometheus: Loki, Alloy (every VM), haproxy (RGW health from each log VM).
  logging_scrape_configs = concat(
    [{
      job_name       = "alloy"
      static_configs = [for name, a in local.alloy_hosts : { targets = ["${a.listen}:12345"], labels = { host = name } }]
    }],
    local.logging_enabled ? [
      {
        job_name       = "loki"
        static_configs = [for name in local.logging_names : { targets = ["${var.logging[name].backend_address}:3100"], labels = { host = name } }]
      },
      {
        job_name       = "haproxy"
        static_configs = [for name in local.logging_names : { targets = ["${var.logging[name].backend_address}:8405"], labels = { host = name } }]
      },
    ] : [],
  )

  logging_rules = local.logging_enabled ? [{
    name = "logging"
    rules = concat(
      [
        {
          alert       = "LokiRingUnhealthy"
          expr        = "max by (name) (loki_ring_members{job=\"loki\", state=\"Unhealthy\"}) > 0"
          for         = "5m"
          labels      = { severity = "warning" }
          annotations = { summary = "Loki ring {{ $labels.name }} has {{ $value }} unhealthy member(s)" }
        },
        {
          alert       = "LokiRingMembersMissing"
          expr        = "min(loki_ring_members{job=\"loki\", name=\"ingester\", state=\"ACTIVE\"}) < ${length(var.logging)}"
          for         = "10m"
          labels      = { severity = "warning" }
          annotations = { summary = "Loki ingester ring has fewer than ${length(var.logging)} ACTIVE members" }
        },
        {
          alert       = "LokiIngesterFlushFailures"
          expr        = "sum by (host) (increase(loki_ingester_chunks_flush_failures_total{job=\"loki\"}[15m])) > 0"
          for         = "5m"
          labels      = { severity = "critical" }
          annotations = { summary = "Loki on {{ $labels.host }} fails to flush chunks to S3 (RGW)" }
        },
        {
          alert       = "SyslogIngestStopped"
          expr        = "sum(rate(loki_source_syslog_entries_total{job=\"alloy\"}[15m])) == 0"
          for         = "15m"
          labels      = { severity = "warning" }
          annotations = { summary = "No syslog message reached Alloy on the logging VMs for 30 minutes" }
        },
        {
          alert       = "AlloyLokiWriteDrops"
          expr        = "sum by (host, reason) (increase(loki_write_dropped_entries_total{job=\"alloy\"}[15m])) > 0"
          for         = "5m"
          labels      = { severity = "warning" }
          annotations = { summary = "Alloy on {{ $labels.host }} dropped log entries ({{ $labels.reason }})" }
        },
        {
          alert       = "RGWBackendDegraded"
          expr        = "haproxy_backend_active_servers{job=\"haproxy\", proxy=\"rgw\"} < ${length(var.logging_settings.rgw_endpoints)}"
          for         = "5m"
          labels      = { severity = "warning" }
          annotations = { summary = "haproxy on {{ $labels.host }} sees only {{ $value }} healthy RGW(s)" }
        },
        {
          alert       = "RGWBackendDown"
          expr        = "haproxy_backend_active_servers{job=\"haproxy\", proxy=\"rgw\"} == 0"
          for         = "2m"
          labels      = { severity = "critical" }
          annotations = { summary = "haproxy on {{ $labels.host }} has no healthy RGW: Loki can't reach S3" }
        },
      ],
      [for net, ip in local.vip_address : {
        alert       = "LoggingVIPNotHeldOnce"
        expr        = "count(node_network_address_info{job=\"node\", role=\"logging\", address=\"${ip}\"}) != 1 or absent(node_network_address_info{job=\"node\", role=\"logging\", address=\"${ip}\"})"
        for         = "2m"
        labels      = { severity = "critical", vip = ip, network = net }
        annotations = { summary = "Logging VIP ${ip} (${net}) is held by {{ $value }} VMs instead of exactly one" }
      }],
    )
  }] : []

  loki_datasource = local.logging_enabled ? [{
    name   = "Loki"
    uid    = "loki"
    type   = "loki"
    access = "proxy"
    url    = local.loki_url
    jsonData = {
      maxLines     = 1000
      manageAlerts = false # the ruler's rules are files on the log VMs
      # Every stream has a host label (the same value Prometheus uses): link it to that host's targets.
      derivedFields = [{
        name          = "host metrics"
        matcherType   = "label"
        matcherRegex  = "host"
        datasourceUid = "prometheus"
        # $$ keeps Grafana's provisioning from expanding it as an environment variable.
        url             = "up{host=\"$$${__value.raw}\"}"
        urlDisplayLabel = "Prometheus targets of this host"
      }]
    }
  }] : []
}
