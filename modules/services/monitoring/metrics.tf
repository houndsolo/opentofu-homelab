# Metrics: Grafana Mimir (monolithic, 3-instance ring, classic architecture) on the
# role = "metrics" VMs (mim01-03), the long-term store behind Prometheus HA. Each VM also
# runs haproxy (S3 to the Ceph RGWs), keepalived (the Mimir VIP), node_exporter and Alloy
# (journal -> Loki), like the Loki VMs in logging.tf.
#
# Both Prometheus replicas (mon01/mon02) remote_write everything to the VIP; Mimir's HA
# tracker keeps one replica's samples (labels ha_cluster / __replica__ from their
# external_labels) and drops ha_cluster and site afterwards, so the stored series are
# exactly what each Prometheus has locally (and what the backfilled history has).

locals {
  metrics_conf = "/etc/metrics"
  metrics_data = "/var/lib/metrics"

  # Without secrets (no RGW user yet) Mimir is left out entirely: no deployment, Prometheus
  # keeps no remote_write and Grafana's "prometheus" datasource stays on Prometheus.
  mimir_enabled   = length(var.metrics) > 0 && nonsensitive(var.metrics_secrets != null)
  metrics_secrets = local.mimir_enabled ? var.metrics_secrets : { s3_bucket = "", s3_access_key = "", s3_secret_key = "" }
  metrics_names   = sort(keys(var.metrics))
  ms              = var.metrics_settings

  mimir_http_port       = 8080 # Mimir's defaults: dedicated VMs, nothing else to collide with
  mimir_grpc_port       = 9095
  mimir_memberlist_port = 7946
  mimir_vip             = split("/", local.ms.vip)[0]
  mimir_url             = "http://${local.mimir_vip}:${local.mimir_http_port}"

  # VRRP priority by name order, as for the Loki VMs (first election only: nopreempt).
  metrics_priority = { for i, name in local.metrics_names : name => max(150 - 50 * i, 10) }

  mimir_s3_bucket = local.mimir_enabled ? nonsensitive(local.metrics_secrets.s3_bucket) : ""

  # --- Interface with main.tf (Prometheus remote_write, Grafana datasource) ---
  mimir_remote_write = local.mimir_enabled ? [{
    name = "mimir"
    url  = "${local.mimir_url}/api/v1/push"
    # Small: ~4k samples/s. Prometheus retries on 5xx/429 and replays its WAL, so a VIP
    # failover or a Mimir restart only delays samples (up to the WAL's ~2 h).
    queue_config    = { capacity = 10000, max_shards = 10, max_samples_per_send = 2000, batch_send_deadline = "5s" }
    metadata_config = { send = true }
  }] : []
  mimir_query_url = local.mimir_enabled ? "${local.mimir_url}/prometheus" : null
  mimir_datasource_json = local.mimir_enabled ? {
    prometheusType = "Mimir"
    httpMethod     = "POST"
    timeInterval   = "30s"
  } : {}

  # --- Mimir config, one per VM (ring addresses) ---
  mimir_yml = {
    for name, vm in var.metrics : name => yamlencode({
      target               = "all" # distributor, ingester, querier, query-frontend/scheduler, store-gateway, compactor, ruler
      multitenancy_enabled = false # everything goes to the "anonymous" tenant
      usage_stats          = { enabled = false }
      # Mimir 3.x still defaults to the classic architecture (ingest storage needs Kafka); pinned explicitly.
      ingest_storage = { enabled = false }

      server = {
        # Every address, so the VIP works wherever it is; metrics-guard (nftables) limits 8080
        # to loopback and the backend VLAN, 9095/7946 to loopback and the HA addresses. gRPC must
        # include the HA addresses: frontends and queriers reach every scheduler through the ring.
        http_listen_address = ""
        http_listen_port    = local.mimir_http_port
        grpc_listen_address = ""
        grpc_listen_port    = local.mimir_grpc_port
        log_level           = "info"
      }

      memberlist = {
        cluster_label               = "lylat-mimir"
        bind_addr                   = [vm.ha_address]
        bind_port                   = local.mimir_memberlist_port
        advertise_addr              = vm.ha_address
        advertise_port              = local.mimir_memberlist_port
        join_members                = [for peer in local.metrics_names : "${var.metrics[peer].ha_address}:${local.mimir_memberlist_port}"]
        abort_if_cluster_join_fails = false
      }

      # Every ring uses memberlist (the default) and the HA address.
      distributor = {
        ring = { instance_addr = vm.ha_address }
        ha_tracker = {
          enable_ha_tracker             = true
          enable_elected_replica_metric = true # cortex_ha_tracker_elected_replica_status: which replica is accepted
          kvstore                       = { store = "memberlist" }
        }
      }
      ingester = {
        ring = {
          instance_addr      = vm.ha_address
          replication_factor = local.ms.replication_factor
          tokens_file_path   = "/data/tokens/ingester"
        }
      }
      querier = { ring = { instance_addr = vm.ha_address } }
      # Ring-based scheduler discovery: every frontend enqueues on, and every querier pulls from,
      # all three schedulers, so a dashboard burst arriving on the VIP holder is executed by all
      # nodes' queriers (default 'dns' mode keeps each node on its own in-process scheduler: all
      # queries ran on mim01 and hit the 100-request queue limit, HTTP 429). Log review 2026-11-10 #12.
      query_scheduler = {
        service_discovery_mode              = "ring"
        max_outstanding_requests_per_tenant = 800
        ring                                = { instance_addr = vm.ha_address }
      }
      frontend = { address = vm.ha_address }
      store_gateway = {
        sharding_ring = {
          instance_addr    = vm.ha_address
          tokens_file_path = "/data/tokens/store-gateway"
        }
      }
      compactor = {
        data_dir      = "/data/compactor"
        sharding_ring = { instance_addr = vm.ha_address }
      }
      # The ruler runs (it's part of "all") but has no rules: alerting stays in Prometheus.
      ruler         = { rule_path = "/data/ruler", ring = { instance_addr = vm.ha_address } }
      ruler_storage = { backend = "filesystem", filesystem = { dir = "/data/rules" } }

      blocks_storage = {
        backend = "s3"
        s3 = {
          endpoint           = "127.0.0.1:7480" # local haproxy -> RGWs
          region             = "default"
          bucket_name        = local.mimir_s3_bucket
          access_key_id      = "$${MIMIR_S3_ACCESS_KEY}"
          secret_access_key  = "$${MIMIR_S3_SECRET_KEY}"
          insecure           = true
          bucket_lookup_type = "path"
        }
        tsdb         = { dir = "/data/tsdb" } # WAL + the last 13 h of blocks (default retention_period)
        bucket_store = { sync_dir = "/data/tsdb-sync" }
      }
      activity_tracker = { filepath = "/data/metrics-activity.log" }

      limits = {
        accept_ha_samples = true
        ha_cluster_label  = local.ms.ha_cluster_label
        ha_replica_label  = local.ms.ha_replica_label
        # Applied after HA deduplication: the HA cluster label and site only describe the senders.
        drop_labels                       = local.ms.drop_labels
        max_global_series_per_user        = local.ms.max_series
        ingestion_rate                    = local.ms.ingestion_rate
        ingestion_burst_size              = local.ms.ingestion_burst_size
        max_label_names_per_series        = local.ms.max_label_names_per_series
        out_of_order_time_window          = local.ms.out_of_order_time_window # replica failover can resend a little older data
        compactor_blocks_retention_period = local.ms.retention_period
        compactor_block_upload_enabled    = local.ms.block_upload_enabled # mimirtool backfill
      }
    })
  }

  mimir_env = local.mimir_enabled ? "MIMIR_S3_ACCESS_KEY=${local.metrics_secrets.s3_access_key}\nMIMIR_S3_SECRET_KEY=${local.metrics_secrets.s3_secret_key}\n" : ""

  # Alloy on these VMs: journal only, to the Loki VIP (merged into alloy_hosts in logging.tf).
  mimir_alloy_hosts = local.mimir_enabled ? {
    for name, vm in var.metrics : name => { listen = coalesce(vm.telemetry_address, vm.backend_address), loki_url = local.loki_push_url, syslog = false }
  } : {}

  metrics_keepalived_conf = {
    for name, vm in var.metrics : name => templatefile("${path.module}/templates/metrics-keepalived.conf.tftpl", {
      host          = name
      router_id     = local.ms.vrrp_router_id
      priority      = local.metrics_priority[name]
      mimir_port    = local.mimir_http_port
      ha_interface  = vm.interfaces.ha
      ha_address    = vm.ha_address
      peers         = [for peer in local.metrics_names : var.metrics[peer].ha_address if peer != name]
      vip           = local.ms.vip
      vip_interface = vm.interfaces.backend
    })
  }

  metrics_haproxy_cfg = {
    for name, vm in var.metrics : name => templatefile("${path.module}/templates/haproxy.cfg.tftpl", {
      host          = name
      client        = "Mimir"
      endpoints     = local.ms.rgw_endpoints
      stats_address = vm.backend_address
    })
  }

  metrics_guard_nft = templatefile("${path.module}/templates/metrics-guard.nft.tftpl", {
    http_port       = local.mimir_http_port
    grpc_port       = local.mimir_grpc_port
    memberlist_port = local.mimir_memberlist_port
    sources         = local.ms.allowed_sources
    ring_sources    = [for name in local.metrics_names : var.metrics[name].ha_address]
  })

  metrics_units = {
    for name, vm in var.metrics : name => {
      haproxy = templatefile("${path.module}/templates/haproxy.container.tftpl", { image = var.images.haproxy, conf_dir = local.metrics_conf })
      mimir   = templatefile("${path.module}/templates/mimir.container.tftpl", { image = var.images.mimir, ring_size = length(var.metrics) })
      # address-info: node_network_address_info shows which VM holds the VIP.
      node-exporter = templatefile("${path.module}/templates/node-exporter.container.tftpl", {
        image          = var.images.node_exporter
        listen_address = coalesce(vm.telemetry_address, vm.backend_address)
        textfile_dir   = null
      })
    }
  }

  # Start order: the guard before Mimir opens its ports, S3 before Mimir, keepalived last.
  metrics_services = ["metrics-guard", "haproxy", "mimir", "alloy", "node-exporter", "keepalived"]

  metrics_files = {
    for name, vm in var.metrics : name => concat(
      [for unit in ["haproxy", "mimir", "node-exporter"] : { path = "${local.quadlet_dir}/${unit}.container", content = local.metrics_units[name][unit], units = [unit] }],
      lookup(local.alloy_files, name, []), # (mimir_alloy_hosts is empty when Mimir is off)
      [
        { path = "${local.metrics_conf}/haproxy/haproxy.cfg", content = local.metrics_haproxy_cfg[name], units = ["haproxy"], restart = true },
        { path = "${local.metrics_conf}/mimir/mimir.yaml", content = local.mimir_yml[name], units = ["mimir"], restart = true },
        { path = "${local.metrics_conf}/mimir.env", mode = "0600", content = local.mimir_env, units = ["mimir"], restart = true },
        { path = "${local.metrics_conf}/guard.nft", content = local.metrics_guard_nft, units = ["metrics-guard"], restart = true },
        { path = "/etc/systemd/system/metrics-guard.service", content = file("${path.module}/templates/metrics-guard.service"), units = ["metrics-guard"] },
        { path = "/etc/keepalived/keepalived.conf", mode = "0600", content = local.metrics_keepalived_conf[name], units = ["keepalived"] },
      ],
    )
  }

  # --- Prometheus: scrape jobs, alerts ---
  mimir_scrape_configs = local.mimir_enabled ? [
    {
      job_name       = "mimir"
      static_configs = [for name in local.metrics_names : { targets = ["${var.metrics[name].backend_address}:${local.mimir_http_port}"], labels = { host = name } }]
    },
    {
      # haproxy on the Mimir VMs (RGW health); job "haproxy" is the Loki VMs'.
      job_name       = "haproxy-mimir"
      static_configs = [for name in local.metrics_names : { targets = ["${var.metrics[name].backend_address}:8405"], labels = { host = name } }]
    },
  ] : []

  mimir_rules = local.mimir_enabled ? [{
    name = "metrics"
    rules = [
      {
        alert       = "MimirRingMembersMissing"
        expr        = "min by (name) (cortex_ring_members{job=\"mimir\", name=~\"ingester|store-gateway|compactor|distributor\", state=\"ACTIVE\"}) < ${length(var.metrics)}"
        for         = "10m"
        labels      = { severity = "warning" }
        annotations = { summary = "Mimir {{ $labels.name }} ring has fewer than ${length(var.metrics)} ACTIVE members" }
      },
      {
        alert       = "MimirRingUnhealthy"
        expr        = "max by (name) (cortex_ring_members{job=\"mimir\", state=\"Unhealthy\"}) > 0"
        for         = "5m"
        labels      = { severity = "warning" }
        annotations = { summary = "Mimir {{ $labels.name }} ring has {{ $value }} unhealthy member(s) (forget a rebuilt VM's old entry on /ingester/ring)" }
      },
      {
        alert       = "MimirBlockUploadFailures"
        expr        = "sum by (host) (increase(cortex_ingester_shipper_upload_failures_total{job=\"mimir\"}[15m])) > 0"
        for         = "5m"
        labels      = { severity = "critical" }
        annotations = { summary = "Mimir on {{ $labels.host }} fails to ship TSDB blocks to S3 (RGW)" }
      },
      {
        alert       = "MimirCompactorNotRunning"
        expr        = "(time() - max(cortex_compactor_last_successful_run_timestamp_seconds{job=\"mimir\"})) > 86400"
        for         = "1h"
        labels      = { severity = "warning" }
        annotations = { summary = "No Mimir compactor run succeeded for a day (compaction and retention stalled)" }
      },
      {
        alert       = "MimirDiscardingSamples"
        expr        = "sum by (reason) (rate(cortex_discarded_samples_total{job=\"mimir\", reason!=\"replicas_did_not_match\"}[10m])) > 0"
        for         = "15m"
        labels      = { severity = "warning" }
        annotations = { summary = "Mimir is discarding samples ({{ $labels.reason }}): a limit may need raising" }
      },
      {
        alert       = "PrometheusRemoteWriteFailing"
        expr        = "sum by (host) (rate(prometheus_remote_storage_samples_failed_total{job=\"prometheus\"}[10m])) > 0"
        for         = "10m"
        labels      = { severity = "warning" }
        annotations = { summary = "Prometheus on {{ $labels.host }} fails to remote_write samples to Mimir" }
      },
      {
        alert       = "PrometheusRemoteWriteBehind"
        expr        = "max by (host) (prometheus_remote_storage_highest_timestamp_in_seconds{job=\"prometheus\"} - ignoring(remote_name, url) group_right prometheus_remote_storage_queue_highest_sent_timestamp_seconds{job=\"prometheus\"}) > 300"
        for         = "10m"
        labels      = { severity = "warning" }
        annotations = { summary = "Prometheus on {{ $labels.host }} is {{ $value | humanizeDuration }} behind in its remote_write to Mimir" }
      },
      {
        alert       = "MimirRGWBackendDown"
        expr        = "haproxy_backend_active_servers{job=\"haproxy-mimir\", proxy=\"rgw\"} == 0"
        for         = "2m"
        labels      = { severity = "critical" }
        annotations = { summary = "haproxy on {{ $labels.host }} has no healthy RGW: Mimir can't reach S3" }
      },
      {
        alert       = "MimirVIPNotHeldOnce"
        expr        = "count(node_network_address_info{job=\"node\", role=\"metrics\", address=\"${local.mimir_vip}\"}) != 1 or absent(node_network_address_info{job=\"node\", role=\"metrics\", address=\"${local.mimir_vip}\"})"
        for         = "2m"
        labels      = { severity = "critical", vip = local.mimir_vip, network = "backend" }
        annotations = { summary = "Mimir VIP ${local.mimir_vip} is held by {{ $value }} VMs instead of exactly one" }
      },
    ]
  }] : []
}

# One deploy script per Mimir VM. Mimir's /ready needs the ring and haproxy's port an RGW, so those are
# checked from the host after the restarts (verify), not in the units.
module "metrics_deploy" {
  source   = "../quadlet-deploy"
  for_each = local.mimir_enabled ? var.metrics : {}

  name     = "metrics"
  host     = each.key
  images   = [var.images.haproxy, var.images.mimir, var.images.alloy, var.images.node_exporter]
  packages = ["keepalived"]
  # The mimir image runs as root. compactor: block-upload validation needs it, but Mimir only creates
  # it at the first compaction; rules: ruler_storage (empty).
  dirs = concat(
    [for d in ["", "/tokens", "/rules", "/compactor"] : { path = "${local.metrics_data}/mimir${d}", mode = "0750", owner = "0:0" }],
    local.alloy_dirs,
  )
  files = local.metrics_files[each.key]
  checks = [
    # -modules parses the file strictly (unknown keys fail), validates it and exits without starting.
    "podman run --rm --network=none --user 0 -v \"$stage${local.metrics_conf}/mimir:/etc/mimir:ro\" '${var.images.mimir}' -config.file=/etc/mimir/mimir.yaml -config.expand-env=true -modules >/dev/null",
    local.alloy_check[each.key],
    "podman run --rm --network=none --user 0 -v \"$stage${local.metrics_conf}/haproxy:/usr/local/etc/haproxy:ro\" '${var.images.haproxy}' haproxy -c -q -f /usr/local/etc/haproxy/haproxy.cfg",
    "nft -c -f \"$stage${local.metrics_conf}/guard.nft\"",
    local.keepalived_validation,
  ]
  post_install = ["systemctl enable --quiet metrics-guard.service keepalived.service"]
  units        = local.metrics_services
  verify = [
    "retry curl -fsS -o /dev/null --max-time 3 http://127.0.0.1:7480/", # haproxy -> an RGW
    # Ready once its ingester is ACTIVE in the ring (on first start: once every ring member is healthy).
    "retry curl -fsS -o /dev/null --max-time 3 http://127.0.0.1:${local.mimir_http_port}/ready",
    local.alloy_verify[each.key],
    "retry nft list table inet metrics_guard",
  ]
}
