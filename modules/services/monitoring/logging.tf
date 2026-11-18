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
  logging_secrets = var.logging_secrets != null ? var.logging_secrets : { s3_bucket = "", s3_access_key = "", s3_secret_key = "" }
  logging_names   = sort(keys(var.logging))
  logging_vips    = var.logging_settings.vips
  # Every logging VM's HA address (sorted: memberlist join list, keepalived peers, ring guard).
  logging_ring_peers = sort(distinct([for name in local.logging_names : var.logging[name].ha_address]))
  vip_address        = { for net, cidr in local.logging_vips : net => split("/", cidr)[0] if cidr != null }
  # Grafana's datasource and the README use the backend VIP.
  loki_url = "http://${local.vip_address.backend}:3100"
  # Alloy pushes from every other VM: the telemetry VIP (lylat-telemetry, zone design) when set, else the backend VIP.
  loki_push_url = contains(keys(local.vip_address), "telemetry") ? "http://${local.vip_address.telemetry}:3100" : local.loki_url

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
        join_members                = [for a in local.logging_ring_peers : "${a}:7946"]
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
        # Every Alertmanager (one group each, so each gets every alert; the cluster dedups), over the backend VLAN.
        alertmanager_url = join(",", [for t in local.alertmanager_targets : "http://${t}"])
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
  # RouterOS boxes (every SNMP job walking mikrotik_lite) and the PVE nodes (node targets with role=proxmox,
  # greatfox included), by their Loki host label.
  routeros_hosts = sort(distinct(flatten([for j in values(var.targets.snmp) : keys(j.targets) if contains(j.modules, "mikrotik_lite")])))
  pve_log_hosts  = sort([for t in var.targets.node : t.host if lookup(t.labels, "role", "") == "proxmox"])
  pve_kernel_sel = length(local.pve_log_hosts) == 0 ? "{app=\"kernel\"}" : "{app=\"kernel\", host=~\"${join("|", local.pve_log_hosts)}\"}"
  loki_rules_yml = yamlencode({
    groups = [{
      name = "logging"
      rules = concat(length(local.routeros_hosts) == 0 ? [] : [
        {
          # The spines' side of a leaf session (DT-007). FRR on VyOS never sends %ADJCHANGE (it logs session
          # changes at informational, VyOS forces "log syslog notifications"), so the old ADJCHANGE rule could
          # never fire; the leaves' own view is BGPSessionDown/BFDPeerDown (infra-alerts.tf). leaf-20 is skipped:
          # greatfox is often powered off on purpose and each shutdown logs this for its session on each spine.
          alert       = "RouterOSBGPNoBFD"
          expr        = "sum by (host, session) (count_over_time({host=~\"${join("|", local.routeros_hosts)}\"} |= \"Cannot make BGP session\" != \"leaf-20-\" | regexp `(?P<session>\\S+) Cannot make BGP session` [5m])) > 0"
          labels      = { severity = "warning" }
          annotations = { summary = "{{ $labels.host }}: BGP session {{ $labels.session }} can't come up, its BFD session isn't established (peer down or link loss)" }
        },
        ], [
        {
          # libata link resets / failed NCQ commands (log review 2026-11-10 #3: the Seagate OSDs'
          # SATA links reset under link power management and stalled BlueStore for up to 30 s).
          alert       = "SataLinkReset"
          expr        = "sum by (host) (count_over_time({app=\"kernel\"} |~ \"hard resetting link|failed command: (READ|WRITE) FPDMA|SError: \\\\{\" [15m])) > 0"
          labels      = { severity = "warning" }
          annotations = { summary = "{{ $labels.host }}: SATA link reset / failed NCQ command in the kernel log ({{ $value }} lines in 15m)" }
        },
        {
          # Block-layer read/write failures on the PVE nodes (DT-007; e.g. fortuna 2026-11-09: "I/O error, dev sdb,
          # sector 760696264 op 0x0:(READ)" with "Sense Key : Medium Error"). CD-ROM and loop devices are noise.
          alert       = "KernelDiskIOError"
          expr        = "sum by (host) (count_over_time(${local.pve_kernel_sel} |~ `I/O error, dev |Buffer I/O error on dev|blk_update_request: .*error|Sense Key : Medium Error` !~ `dev (sr|loop)[0-9]` [10m])) > 0"
          labels      = { severity = "warning" }
          annotations = { summary = "{{ $labels.host }}: {{ $value }} disk I/O error lines in the kernel log in 10m (check SMART and the disk's OSD/pool)" }
        },
        {
          # Machine checks (DT-007; titania 2026-11-09 deferred UECC, fichina MC "System Fatal error" after
          # reboots). The kernel logs one "Machine check events logged" line per event, the details next to it.
          alert       = "KernelHardwareError"
          expr        = "sum by (host) (count_over_time(${local.pve_kernel_sel} |= `mce: [Hardware Error]: Machine check events logged` [10m])) > 0"
          labels      = { severity = "warning" }
          annotations = { summary = "{{ $labels.host }}: machine check (CPU/memory hardware error) in the kernel log; read the [Hardware Error] lines around it" }
        },
      ])
    }]
  })

  loki_env = local.logging_enabled ? "LOKI_S3_ACCESS_KEY=${local.logging_secrets.s3_access_key}\nLOKI_S3_SECRET_KEY=${local.logging_secrets.s3_secret_key}\n" : ""

  # Alloy everywhere: journal -> Loki; on the logging VMs also the syslog receiver,
  # pushing to the local Loki (which replicates to the others).
  alloy_hosts = merge(
    { for name, b in var.backends : name => { listen = coalesce(b.telemetry_address, b.backend_address), loki_url = local.loki_push_url, syslog = false } },
    { for name, g in var.grafana : name => { listen = coalesce(g.telemetry_address, g.backend_address), loki_url = local.loki_push_url, syslog = false } },
    { for name, vm in var.logging : name => { listen = coalesce(vm.telemetry_address, vm.backend_address), loki_url = "http://127.0.0.1:3100", syslog = true } },
    local.mimir_alloy_hosts, # metrics.tf
    local.pg_alloy_hosts,    # postgres.tf
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
      # Loki host labels whose imuxsock duplicates (one leading space) are dropped.
      dedup_hosts = var.logging_settings.syslog_dedup_hosts
    })
  }
  alloy_unit = {
    for name, a in local.alloy_hosts : name => templatefile("${path.module}/templates/alloy.container.tftpl", {
      image          = var.images.alloy
      listen_address = a.listen
      syslog         = a.syslog # also the syslog receiver (logging VMs)
    })
  }
  alloy_dirs = [{ path = local.alloy_data, mode = "0750", owner = "0:0" }] # the alloy image runs as root
  alloy_files = {
    for name in keys(local.alloy_hosts) : name => [
      { path = "${local.quadlet_dir}/alloy.container", content = local.alloy_unit[name], units = ["alloy"] },
      { path = "${local.alloy_conf}/config.alloy", content = local.alloy_config[name], units = ["alloy"] },
    ]
  }
  # The syslog receiver's raw listener (Cisco IOS-XE, FS S3910: not RFC 3164) is
  # experimental in Alloy; "alloy validate" doesn't check stability, "run" refuses it.
  alloy_check = {
    for name, a in local.alloy_hosts : name => join(" ", concat([
      "podman run --rm --network=none --user 0 -v \"$stage${local.alloy_conf}:/etc/alloy:ro\" '${var.images.alloy}' validate",
    ], a.syslog ? ["--stability.level=experimental"] : [], ["/etc/alloy/config.alloy"]))
  }
  # From the host: the alloy image has neither curl nor wget for a HealthCmd.
  alloy_verify = { for name, a in local.alloy_hosts : name => "retry curl -fsS -o /dev/null --max-time 3 http://${a.listen}:12345/-/ready" }

  # keepalived: one VRRP instance per network, unicast to the other logging VMs.
  keepalived_conf = {
    for name, vm in var.logging : name => templatefile("${path.module}/templates/keepalived.conf.tftpl", {
      host          = name
      router_id     = var.logging_settings.vrrp_router_id
      priority      = local.logging_priority[name]
      alloy_address = coalesce(vm.telemetry_address, vm.backend_address)
      ha_interface  = vm.interfaces.ha
      ha_address    = vm.ha_address
      peers         = [for a in local.logging_ring_peers : a if a != vm.ha_address]
      vips = [
        for net in ["backend", "monitoring", "telemetry"] : { cidr = local.logging_vips[net], interface = vm.interfaces[net] }
        if local.logging_vips[net] != null && try(vm.interfaces[net], null) != null
      ]
    })
  }

  logging_units = {
    for name, vm in var.logging : name => {
      haproxy = templatefile("${path.module}/templates/haproxy.container.tftpl", { image = var.images.haproxy, conf_dir = local.logging_conf })
      loki    = templatefile("${path.module}/templates/loki.container.tftpl", { image = var.images.loki, ring_size = length(var.logging) })
      alloy   = local.alloy_unit[name]
      # address-info: node_network_address_info shows which VM holds each VIP.
      node-exporter = templatefile("${path.module}/templates/node-exporter.container.tftpl", {
        image          = var.images.node_exporter
        listen_address = coalesce(vm.telemetry_address, vm.backend_address)
        textfile_dir   = null
      })
    }
  }

  # Start order: the guard before Loki opens its ports, S3 before Loki, keepalived last.
  logging_services = ["logging-guard", "haproxy", "loki", "alloy", "node-exporter", "keepalived"]

  logging_files = {
    for name, vm in var.logging : name => concat(
      [for unit in ["haproxy", "loki", "alloy", "node-exporter"] : { path = "${local.quadlet_dir}/${unit}.container", content = local.logging_units[name][unit], units = [unit] }],
      [for f in local.alloy_files[name] : f if f.path != "${local.quadlet_dir}/alloy.container"],
      [
        { path = "${local.logging_conf}/haproxy/haproxy.cfg", content = local.haproxy_cfg[name], units = ["haproxy"], restart = true },
        { path = "${local.logging_conf}/loki/loki.yaml", content = local.loki_yml[name], units = ["loki"], restart = true },
        # The ruler polls the rules directory: no restart.
        { path = "${local.logging_conf}/loki/rules/fake/logging.yaml", content = local.loki_rules_yml },
        { path = "${local.logging_conf}/loki.env", mode = "0600", content = local.loki_env, units = ["loki"], restart = true },
        { path = "${local.logging_conf}/guard.nft", content = local.guard_nft, units = ["logging-guard"], restart = true },
        { path = "/etc/systemd/system/logging-guard.service", content = file("${path.module}/templates/logging-guard.service"), units = ["logging-guard"] },
        { path = "/etc/keepalived/keepalived.conf", mode = "0600", content = local.keepalived_conf[name], units = ["keepalived"] },
      ],
    )
  }

  haproxy_cfg = {
    for name, vm in var.logging : name => templatefile("${path.module}/templates/haproxy.cfg.tftpl", {
      host          = name
      client        = "Loki"
      endpoints     = var.logging_settings.rgw_endpoints
      stats_address = vm.backend_address
    })
  }

  guard_nft = templatefile("${path.module}/templates/logging-guard.nft.tftpl", {
    sources      = var.logging_settings.loki_allowed_sources
    ring_sources = local.logging_ring_peers
  })

  # Prometheus: Loki, Alloy (every VM, plus services-config's VMs from targets.alloy), haproxy (RGW health from each log VM).
  logging_scrape_configs = concat(
    [{
      job_name = "alloy"
      static_configs = concat(
        [for name, a in local.alloy_hosts : { targets = ["${a.listen}:12345"], labels = { host = name } }],
        [for t in var.targets.alloy : { targets = ["${t.address}:12345"], labels = { host = t.host } }],
      )
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
      # Every stream has a host label, the name Prometheus uses too, but Loki has the VyOS hosts in
      # upper case (LEAF-11 vs leaf-11), so the link ignores case. It opens that host's targets.
      derivedFields = [{
        name          = "host metrics"
        matcherType   = "label"
        matcherRegex  = "host"
        datasourceUid = "prometheus"
        # $$ keeps Grafana's provisioning from expanding it as an environment variable.
        url             = "up{host=~\"(?i)$$${__value.raw}\"}"
        urlDisplayLabel = "Prometheus targets of this host"
      }]
    }
  }] : []
}

# One deploy script per logging VM. Loki's /ready needs the ring and haproxy's port an RGW, so those are
# checked from the host after the restarts (verify), not in the units.
module "logging_deploy" {
  source   = "../quadlet-deploy"
  for_each = var.logging

  name     = "logging"
  host     = each.key
  images   = [var.images.haproxy, var.images.loki, var.images.alloy, var.images.node_exporter]
  packages = ["keepalived"]
  dirs = concat(
    [{ path = "${local.logging_data}/loki", mode = "0750", owner = "10001:10001" }], # the loki image's user
    local.alloy_dirs,
  )
  prune_dirs = ["${local.logging_conf}/loki/rules"]
  files      = local.logging_files[each.key]
  checks = [
    "podman run --rm --network=none --user 0 -v \"$stage${local.logging_conf}/loki:/etc/loki:ro\" '${var.images.loki}' -config.file=/etc/loki/loki.yaml -config.expand-env=true -verify-config",
    local.alloy_check[each.key],
    "podman run --rm --network=none --user 0 -v \"$stage${local.logging_conf}/haproxy:/usr/local/etc/haproxy:ro\" '${var.images.haproxy}' haproxy -c -q -f /usr/local/etc/haproxy/haproxy.cfg",
    "nft -c -f \"$stage${local.logging_conf}/guard.nft\"",
    local.keepalived_validation,
  ]
  post_install = ["systemctl enable --quiet logging-guard.service keepalived.service"]
  units        = local.logging_services
  verify = [
    "retry curl -fsS -o /dev/null --max-time 3 http://127.0.0.1:7480/", # haproxy -> an RGW
    "retry curl -fsS -o /dev/null --max-time 3 http://127.0.0.1:3100/ready",
    local.alloy_verify[each.key],
    "retry nft list table inet logging_guard",
  ]
}
