# Valkey + Sentinel (NetBox's cache and task queue, valkey01-03; deployed by services-config
# valkey.tf). redis_exporter runs on each VM (services-config valkey-monitoring.tf): :9121 for
# Valkey, :9355 for Sentinel, on the telemetry address. node_exporter is in the node job.
locals {
  valkey_scrape_configs = length(var.targets.valkey) == 0 ? [] : [
    {
      job_name       = "valkey"
      static_configs = [for t in var.targets.valkey : { targets = ["${t.address}:9121"], labels = { host = t.host } }]
    },
    {
      job_name       = "valkey-sentinel"
      static_configs = [for t in var.targets.valkey : { targets = ["${t.address}:9355"], labels = { host = t.host } }]
    },
  ]

  valkey_count = length(var.targets.valkey)

  valkey_rules = local.valkey_count == 0 ? [] : [{
    name = "valkey"
    rules = [
      {
        alert       = "ValkeyDown"
        expr        = "redis_up{job=\"valkey\"} == 0"
        for         = "2m"
        labels      = { severity = "warning" }
        annotations = { summary = "Valkey on {{ $labels.host }} is not answering its exporter" }
      },
      {
        alert       = "ValkeyNoPrimary"
        expr        = "count(redis_instance_info{job=\"valkey\",role=\"master\"}) != 1 or absent(redis_instance_info{job=\"valkey\",role=\"master\"})"
        for         = "1m"
        labels      = { severity = "critical" }
        annotations = { summary = "Valkey has {{ $value }} primaries instead of exactly one: NetBox's cache and job queue are down or split" }
      },
      {
        alert       = "ValkeyReplicaLinkDown"
        expr        = "redis_master_link_up{job=\"valkey\"} == 0"
        for         = "2m"
        labels      = { severity = "warning" }
        annotations = { summary = "Valkey replica {{ $labels.host }} has lost its link to the primary {{ $labels.master_host }}" }
      },
      {
        alert       = "ValkeyReplicasMissing"
        expr        = "sum(redis_connected_slaves{job=\"valkey\"} and on (host) redis_instance_info{job=\"valkey\",role=\"master\"}) < ${local.valkey_count - 1}"
        for         = "5m"
        labels      = { severity = "warning" }
        annotations = { summary = "The Valkey primary has {{ $value }} connected replicas instead of ${local.valkey_count - 1}" }
      },
      {
        alert       = "ValkeyReplicaLag"
        expr        = "redis_connected_slave_lag_seconds{job=\"valkey\"} > 10"
        for         = "5m"
        labels      = { severity = "warning" }
        annotations = { summary = "Valkey replica {{ $labels.slave_ip }} is {{ $value }} s behind the primary {{ $labels.host }}" }
      },
      {
        # maxmemory-policy noeviction: at the limit, writes fail (NetBox jobs and caching break).
        alert       = "ValkeyMemoryHigh"
        expr        = "redis_memory_used_bytes{job=\"valkey\"} / redis_memory_max_bytes{job=\"valkey\"} > 0.8 and redis_memory_max_bytes{job=\"valkey\"} > 0"
        for         = "10m"
        labels      = { severity = "warning" }
        annotations = { summary = "Valkey on {{ $labels.host }} uses {{ $value | humanizePercentage }} of maxmemory (noeviction: writes fail at 100%)" }
      },
      {
        alert       = "ValkeyPersistenceFailing"
        expr        = "redis_rdb_last_bgsave_status{job=\"valkey\"} == 0 or redis_aof_last_write_status{job=\"valkey\"} == 0"
        for         = "5m"
        labels      = { severity = "warning" }
        annotations = { summary = "Valkey on {{ $labels.host }} fails to write its RDB/AOF (disk full or I/O error?)" }
      },
      {
        alert       = "SentinelDown"
        expr        = "redis_up{job=\"valkey-sentinel\"} == 0"
        for         = "2m"
        labels      = { severity = "warning" }
        annotations = { summary = "Valkey Sentinel on {{ $labels.host }} is not answering its exporter" }
      },
      {
        # Each Sentinel's view of how many Sentinels (itself included) are reachable.
        alert       = "SentinelPeersMissing"
        expr        = "redis_sentinel_master_ok_sentinels{job=\"valkey-sentinel\"} < ${local.valkey_count}"
        for         = "5m"
        labels      = { severity = "warning" }
        annotations = { summary = "Sentinel on {{ $labels.host }} sees {{ $value }} of ${local.valkey_count} Sentinels for {{ $labels.master_name }}" }
      },
      {
        alert       = "SentinelQuorumLost"
        expr        = "redis_sentinel_master_ckquorum_status{job=\"valkey-sentinel\"} == 0"
        for         = "1m"
        labels      = { severity = "critical" }
        annotations = { summary = "Sentinel on {{ $labels.host }}: no quorum for {{ $labels.master_name }}, Valkey can't fail over" }
      },
      {
        alert       = "SentinelMasterNotOk"
        expr        = "redis_sentinel_master_status{job=\"valkey-sentinel\",master_status!=\"ok\"} == 1"
        for         = "1m"
        labels      = { severity = "critical" }
        annotations = { summary = "Sentinel on {{ $labels.host }} sees primary {{ $labels.master_address }} as {{ $labels.master_status }}" }
      },
      {
        # The epoch rises on every failover; master_address changes with it (a new series), so
        # compare the max per Sentinel with 15 min ago instead of changes().
        alert       = "SentinelPrimaryChanged"
        expr        = "max by (host, master_name) (redis_sentinel_master_config_epoch{job=\"valkey-sentinel\"}) > max by (host, master_name) (redis_sentinel_master_config_epoch{job=\"valkey-sentinel\"} offset 15m)"
        labels      = { severity = "info" }
        annotations = { summary = "Sentinel on {{ $labels.host }}: {{ $labels.master_name }} failed over in the last 15 min" }
      },
    ]
  }]
}
