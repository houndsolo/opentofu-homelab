mock_provider "random" {
  mock_resource "random_password" {
    defaults = { result = "mockmockmockmockmockmockmockmock" }
  }
}

# keepalived's PASS password is at most 8 characters (the shared mock result is longer).
override_resource {
  target = random_password.grafana_vrrp
  values = { result = "mockvrrp" }
}

mock_provider "influxdb" {
  mock_data "influxdb_organization" {
    defaults = { id = "0123456789abcdef" }
  }
  mock_resource "influxdb_bucket" {
    defaults = { id = "fedcba9876543210" }
  }
}

mock_provider "proxmox" {}

mock_provider "proxmox" {
  alias = "greatfox"
}

variables {
  ssh_private_key_path = "/dev/null"
  pve_api_token        = "mock@pve!mock=00000000-0000-0000-0000-000000000000"
  greatfox_api_token   = "mock@pve!mock=00000000-0000-0000-0000-000000000000"
  loki_s3              = { bucket = "loki", access_key = "MOCKACCESSKEY", secret_key = "mocksecretkeymocksecretkey" }
}

run "inventory_targets" {
  command = plan

  assert {
    condition = (
      output.prometheus_url == "http://10.5.11.30:9090" &&
      output.grafana_urls == { graf01 = "http://10.2.11.31:3000", graf02 = "http://10.2.11.32:3000" } &&
      length(terraform_data.backend) == 1 && length(terraform_data.grafana) == 2
    )
    error_message = "Deploy one backend (mon01) and both Grafana VMs, with UIs on the expected addresses."
  }

  assert {
    condition = (
      strcontains(module.monitoring.prometheus_config, "10.5.1.11:9100") &&    # PVE node on vmbr100
      strcontains(module.monitoring.prometheus_config, "10.13.11.31:9100") &&  # Grafana over the backend VLAN
      strcontains(module.monitoring.prometheus_config, "10.20.10.17:9342") &&  # leaf FRR exporter
      strcontains(module.monitoring.prometheus_config, "10.20.10.255:9100") && # fw-wan extra target
      strcontains(module.monitoring.prometheus_config, "\"snmp-spines\"") &&
      strcontains(module.monitoring.prometheus_config, "10.8.53.1") && # DNS SOA probe on the service address
      !strcontains(module.monitoring.prometheus_config, "\"/pve\"")    # no pve job without a token
    )
    error_message = "Scrape targets must come from the inventory, and pve must be absent without a token."
  }

  assert {
    condition = (
      strcontains(module.monitoring.datasources_config, "http://10.13.11.30:9090") &&
      strcontains(module.monitoring.datasources_config, "$INFLUXDB_TOKEN") &&
      !contains(module.monitoring.backend_services, "pve-exporter")
    )
    error_message = "Grafana datasources use the backend VLAN; the InfluxDB token stays an env reference."
  }

  assert {
    condition = (
      strcontains(nonsensitive(module.monitoring.backend_deployment), "promtool") &&
      strcontains(module.monitoring.units.mon01.postgres, "PublishPort=10.13.11.30:5432:5432\n") &&
      !strcontains(module.monitoring.units.mon01.postgres, "10.5.11.30") &&
      strcontains(module.monitoring.units.graf01.grafana, "GF_UNIFIED_ALERTING_HA_PEERS=10.21.11.31:9094,10.21.11.32:9094") &&
      strcontains(module.monitoring.units.graf02["node-exporter"], "--web.listen-address=10.13.11.32:9100") &&
      strcontains(module.monitoring.units.mon01.prometheus, "ExecReload=/usr/bin/podman kill --signal HUP prometheus") &&
      # Data dirs of images that drop from root to a service user stay owned by that user,
      # so a redeploy that doesn't restart Postgres/InfluxDB can't lock them out.
      strcontains(nonsensitive(module.monitoring.backend_deployment), "ensure_dir '/var/lib/monitoring/postgres' '0700' 'user|docker.io/library/postgres:17|postgres'") &&
      strcontains(nonsensitive(module.monitoring.backend_deployment), "ensure_dir '/var/lib/monitoring/influxdb/data' '0700' 'user|docker.io/library/influxdb:2.8|influxdb'")
    )
    error_message = "Validate before install, bind Postgres to the backend VLAN only, and peer Grafana over it."
  }

  assert {
    condition = (
      strcontains(module.monitoring.dashboard_providers_config, "\"path\": \"/etc/grafana/provisioning/dashboards/files\"") &&
      strcontains(module.monitoring.dashboard_providers_config, "\"foldersFromFilesStructure\": true") &&
      strcontains(module.monitoring.dashboard_providers_config, "\"allowUiUpdates\": false") &&
      { for rel, content in module.monitoring.dashboards : rel => jsondecode(content).uid } == {
        "Edge/fw-wan-firewall.json"            = "fw-wan-firewall"
        "Edge/fw-wan-overview.json"            = "fw-wan-overview"
        "Edge/fw-wan-routing.json"             = "fw-wan-routing"
        "Edge/fw-wan-vpn.json"                 = "fw-wan-vpn"
        "Hosts/node-exporter-full.json"        = "node-exporter-full"
        "Logs/fw-wan-logs.json"                = "logs-fw-wan"
        "Logs/logs-overview.json"              = "logs-overview"
        "Logs/network-device-logs.json"        = "logs-network"
        "Logs/proxmox-ceph-logs.json"          = "logs-proxmox"
        "Logs/services-logs.json"              = "logs-services"
        "Monitoring/monitoring-stack.json"     = "monitoring-stack"
        "Network/frr-evpn-fabric.json"         = "frr-evpn-fabric"
        "Network/mikrotik-snmp.json"           = "mikrotik-snmp"
        "Network/snmp-device-summary.json"     = "snmp-device-summary"
        "Network/snmp-interface-detail.json"   = "snmp-interface-detail"
        "Overview/overview.json"               = "lylat-overview"
        "Probes/blackbox-probes.json"          = "blackbox-probes"
        "Proxmox/proxmox-cluster-flux.json"    = "proxmox-cluster-flux"
        "Proxmox/proxmox-guest.json"           = "proxmox-guest"
        "Proxmox/proxmox-node.json"            = "proxmox-node"
        "Proxmox/proxmox-overview.json"        = "proxmox-overview"
        "Proxmox/proxmox-storage.json"         = "proxmox-storage"
        "Storage/ceph-cluster.json"            = "ceph-cluster"
        "Storage/ceph-osd.json"                = "ceph-osd"
        "Storage/ceph-cluster-advanced.json"   = "ceph-cluster-advanced"
        "Storage/ceph-filesystem.json"         = "ceph-filesystem"
        "Storage/ceph-osd-device-details.json" = "ceph-osd-device-details"
        "Storage/ceph-osds-overview.json"      = "ceph-osds-overview"
        "Storage/ceph-pool-details.json"       = "ceph-pool-details"
        "Storage/ceph-pools-overview.json"     = "ceph-pools-overview"
        "Storage/ceph-rbd-details.json"        = "ceph-rbd-details"
        "Storage/ceph-rbd-overview.json"       = "ceph-rbd-overview"
      }
    )
    error_message = "Provision the dashboards from dashboards/<Folder>/*.json, with fixed uids, through a file provider that the UI can't save over."
  }

  assert {
    # Every dashboard is in the "Dashboards" dropdown (links to tag lylat), and the overview shows them as buttons.
    condition = alltrue([for rel, content in module.monitoring.dashboards : (
      contains(jsondecode(content).tags, "lylat") &&
      length([for l in jsondecode(content).links : l if l.type == "dashboards" && contains(l.tags, "lylat")]) == 1
      )]) && alltrue([for l in jsondecode(module.monitoring.dashboards["Overview/overview.json"]).links :
      !l.asDropdown if l.type == "dashboards"
    ])
    error_message = "Every dashboard carries the lylat tag and a dashboard-links entry for it."
  }

  assert {
    # The Ceph dashboards (custom and ceph-mixin) share a "Ceph dashboards" dropdown, and the
    # mixin's datasource picker is gone (no query may reference $datasource).
    condition = alltrue([for rel, content in module.monitoring.dashboards : (
      contains(jsondecode(content).tags, "ceph") &&
      length([for l in jsondecode(content).links : l if l.type == "dashboards" && contains(l.tags, "ceph")]) == 1 &&
      !strcontains(content, "$datasource") && !strcontains(content, "$${datasource}")
    ) if startswith(rel, "Storage/")])
    error_message = "Ceph dashboards carry the ceph tag, a Ceph dashboards dropdown, and no $datasource references."
  }

  assert {
    # The fw-wan dashboards (Edge folder) share a "fw-wan dashboards" dropdown; the VRFs & routing
    # one has a router picker that starts on fw-wan.
    condition = alltrue([for rel, content in module.monitoring.dashboards : (
      contains(jsondecode(content).tags, "fw-wan") &&
      length([for l in jsondecode(content).links : l if l.type == "dashboards" && contains(l.tags, "fw-wan")]) == 1
      ) if startswith(rel, "Edge/")]) && (
      [for v in jsondecode(module.monitoring.dashboards["Edge/fw-wan-routing.json"]).templating.list : v.current.value if v.name == "host"] == ["fw-wan"]
    )
    error_message = "The fw-wan dashboards carry the fw-wan tag and dropdown, and the routing one defaults to fw-wan."
  }

  assert {
    # Node Exporter Full serves both node_exporter jobs: pick the job, then a host by its "host" label.
    condition = (
      [for v in jsondecode(module.monitoring.dashboards["Hosts/node-exporter-full.json"]).templating.list : v.name] == ["job", "node"] &&
      strcontains(module.monitoring.dashboards["Hosts/node-exporter-full.json"], "query_result(count by (host, instance) (node_uname_info{job=\\\"$job\\\"}))") &&
      !strcontains(module.monitoring.dashboards["Hosts/node-exporter-full.json"], "$nodename")
    )
    error_message = "Node Exporter Full must offer a job picker and a host picker (host label, instance value)."
  }

  assert {
    condition = alltrue([for name in ["graf01", "graf02"] : strcontains(
      module.monitoring.units[name].grafana,
      "Environment=GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH=/etc/grafana/provisioning/dashboards/files/Overview/overview.json\n"
    )])
    error_message = "The provisioned overview dashboard is Grafana's home page."
  }

  assert {
    # The Proxmox dashboards read InfluxDB (the PVE metric server buckets); some add Prometheus panels.
    # The log dashboards (Logs/) read Loki.
    condition = alltrue([for rel, content in module.monitoring.dashboards : (
      (
        strcontains(content, "{\"type\":\"prometheus\",\"uid\":\"prometheus\"}") ||
        (startswith(rel, "Proxmox/") && strcontains(content, "{\"type\":\"influxdb\",\"uid\":\"influxdb\"}")) ||
        (startswith(rel, "Logs/") && strcontains(content, "{\"type\":\"loki\",\"uid\":\"loki\"}"))
      ) &&
      !strcontains(content, "$${DS_") &&            # import-time placeholders
      !strcontains(content, "DS_PROMETHEUS") &&     # import-time placeholder
      !strcontains(content, "$source") &&           # datasource template variable
      !strcontains(content, "PBFA97CFB590B2093") && # upstream author's datasource uid
      !strcontains(content, "\"type\":\"datasource\",\"query\":\"prometheus\"") &&
      length([for v in jsondecode(content).templating.list : v if v.type == "datasource"]) == 0 &&
      !can(jsondecode(content).__inputs)
    )])
    error_message = "Dashboards must use the provisioned Prometheus datasource (uid \"prometheus\") directly, with nothing to pick at import."
  }

  assert {
    # The log dashboards query only the provisioned Loki datasource and share a "Logs dashboards" dropdown.
    condition = alltrue([for rel, content in module.monitoring.dashboards : (
      contains(jsondecode(content).tags, "logs") &&
      length([for l in jsondecode(content).links : l if l.type == "dashboards" && contains(l.tags, "logs")]) == 1 &&
      length(regexall("\"type\":\"loki\",\"uid\":\"[^\"]*\"", content)) > 0 &&
      length(regexall("\"type\":\"loki\",\"uid\":\"[^\"]*\"", content)) == length(regexall("\"type\":\"loki\",\"uid\":\"loki\"", content))
    ) if startswith(rel, "Logs/")])
    error_message = "Log dashboards carry the logs tag and dropdown and use the provisioned Loki datasource."
  }

  assert {
    # The Proxmox dashboards (custom and community) query only the provisioned InfluxDB datasource,
    # pick the bucket from the two PVE buckets (not buckets(), which lists InfluxDB's own too) and
    # share a "Proxmox dashboards" dropdown.
    condition = alltrue([for rel, content in module.monitoring.dashboards : (
      contains(jsondecode(content).tags, "proxmox") &&
      length([for l in jsondecode(content).links : l if l.type == "dashboards" && contains(l.tags, "proxmox")]) == 1 &&
      length(regexall("\"type\":\"influxdb\",\"uid\":\"[^\"]*\"", content)) > 0 &&
      length(regexall("\"type\":\"influxdb\",\"uid\":\"[^\"]*\"", content)) == length(regexall("\"type\":\"influxdb\",\"uid\":\"influxdb\"", content)) &&
      length([for v in jsondecode(content).templating.list : v if lower(v.name) == "bucket" && v.type == "custom" && v.query == "lylat cluster : pve_cluster,greatfox : pve_greatfox"]) == 1 &&
      !strcontains(content, "buckets()")
    ) if startswith(rel, "Proxmox/")])
    error_message = "Proxmox dashboards carry the proxmox tag and dropdown, use the provisioned InfluxDB datasource and offer only the PVE buckets."
  }

  assert {
    condition = alltrue([for name in ["graf01", "graf02"] : (
      strcontains(nonsensitive(module.monitoring.grafana_deployments[name]), "prune '/etc/grafana-container/provisioning/dashboards/files'") &&
      strcontains(nonsensitive(module.monitoring.grafana_deployments[name]), "ensure_dir '/etc/grafana-container/provisioning/dashboards/files/Network' '0755' 'root'") &&
      strcontains(nonsensitive(module.monitoring.grafana_deployments[name]), "put '/etc/grafana-container/provisioning/dashboards/files/Network/snmp-device-summary.json' '0644' 'root' '' 'grafana'") &&
      alltrue([for dir in ["Hosts", "Monitoring", "Overview", "Probes", "Storage"] : strcontains(
        nonsensitive(module.monitoring.grafana_deployments[name]),
        "ensure_dir '/etc/grafana-container/provisioning/dashboards/files/${dir}' '0755' 'root'"
      )]) &&
      strcontains(nonsensitive(module.monitoring.grafana_deployments[name]), "put '/etc/grafana-container/provisioning/dashboards/dashboards.yml' '0644' 'root' 'grafana' ''")
    )]) && !strcontains(nonsensitive(module.monitoring.backend_deployment), "\nprune '")
    error_message = "Grafana VMs install the dashboards without a restart (the provider polls), restart only for the provider file, and prune removed dashboards."
  }
}

run "pve_exporter_enabled" {
  command = plan

  variables {
    pve_exporter_token = { user = "prometheus@pve", token_name = "exporter", value = "00000000-0000-0000-0000-000000000000" }
  }

  assert {
    condition = (
      strcontains(module.monitoring.prometheus_config, "\"/pve\"") &&
      contains(module.monitoring.backend_services, "pve-exporter") &&
      length(local.targets.pve) == 7 # cluster nodes; standalone greatfox is left out
    )
    error_message = "A token adds pve-exporter and a pve job for the cluster nodes only."
  }

  assert {
    condition     = !strcontains(module.monitoring.prometheus_config, "00000000-0000-0000-0000-000000000000")
    error_message = "The PVE token must not end up in prometheus.yml."
  }
}

run "backend_nic_required" {
  command = plan

  variables {
    vms = {
      mon01 = {
        owner              = "services-vms"
        role               = "monitoring"
        node               = "zoness"
        vm_id              = 1130
        management_address = "10.20.11.30/16"
        network_devices    = [{ bridge = "vmbr100", ipv4_address = "10.5.11.30/16" }]
      }
    }
  }

  expect_failures = [terraform_data.backend]
}

run "snmp_v3_auths" {
  command = plan

  variables {
    snmp_v3_auths = {
      lylat_v3 = { username = "prometheus", password = "authsecret123", priv_password = "privsecret123" }
    }
  }

  assert {
    condition = (
      strcontains(module.monitoring.units.mon01["snmp-exporter"], "Volume=/etc/monitoring/snmp-exporter/auths.yml:/etc/snmp_exporter/auths.yml:ro") &&
      strcontains(module.monitoring.units.mon01["snmp-exporter"], "--config.file=/etc/snmp_exporter/auths.yml") &&
      strcontains(module.monitoring.prometheus_config, "\"lylat_v3\"") &&
      strcontains(nonsensitive(module.monitoring.backend_deployment), "--dry-run")
    )
    error_message = "SNMPv3 auths add a second exporter config file, validated before install, and the WLC job uses them."
  }

  assert {
    condition     = !strcontains(module.monitoring.prometheus_config, "authsecret123") && !strcontains(module.monitoring.units.mon01["snmp-exporter"], "authsecret123")
    error_message = "SNMPv3 secrets must not end up in prometheus.yml or the unit."
  }
}

run "pve_metric_servers" {
  command = plan

  assert {
    condition = (
      output.pve_metric_buckets == { cluster = "pve_cluster", greatfox = "pve_greatfox" } &&
      influxdb_bucket.pve["cluster"].retention_period == 90 * 86400 &&
      proxmox_metrics_server.cluster.server == "10.5.11.30" &&
      proxmox_metrics_server.cluster.influx_bucket == "pve_cluster" &&
      proxmox_metrics_server.cluster.influx_db_proto == "http" &&
      !proxmox_metrics_server.cluster.disable &&
      proxmox_metrics_server.standalone["greatfox"].influx_bucket == "pve_greatfox" &&
      alltrue([for a in influxdb_authorization.pve : length(a.permissions) == 1 && a.permissions[0].action == "write"])
    )
    error_message = "The cluster and greatfox each push over HTTP to mon01, into their own bucket, with a write-only token."
  }
}

run "logging" {
  command = plan

  assert {
    condition = (
      length(terraform_data.logging) == 3 &&
      output.loki_url == "http://10.13.11.40:3100" &&
      output.loki_urls == { log01 = "http://10.13.11.33:3100", log02 = "http://10.13.11.34:3100", log03 = "http://10.13.11.35:3100" }
    )
    error_message = "Deploy Loki on log01-03, reached through the backend VIP."
  }

  assert {
    # The ring (memberlist, ingester gRPC) runs on the HA VLAN; S3 goes through the local haproxy.
    condition = alltrue([for name, i in { log01 = 33, log02 = 34, log03 = 35 } : (
      yamldecode(module.monitoring.loki_configs[name]).common.instance_addr == "10.21.12.${i}" &&
      yamldecode(module.monitoring.loki_configs[name]).memberlist.advertise_addr == "10.21.12.${i}" &&
      yamldecode(module.monitoring.loki_configs[name]).memberlist.join_members == ["10.21.12.33:7946", "10.21.12.34:7946", "10.21.12.35:7946"] &&
      yamldecode(module.monitoring.loki_configs[name]).common.replication_factor == 3 &&
      yamldecode(module.monitoring.loki_configs[name]).common.storage.s3.endpoint == "127.0.0.1:7480" &&
      yamldecode(module.monitoring.loki_configs[name]).common.storage.s3.bucketnames == "loki" &&
      yamldecode(module.monitoring.loki_configs[name]).ruler.alertmanager_url == "http://10.13.11.30:9093" &&
      yamldecode(module.monitoring.loki_configs[name]).limits_config.retention_period == "90d" &&
      yamldecode(module.monitoring.loki_configs[name]).compactor.retention_enabled &&
      yamldecode(module.monitoring.loki_configs[name]).schema_config.configs[0].schema == "v13" &&
      !strcontains(module.monitoring.loki_configs[name], "MOCKACCESSKEY") &&
      !strcontains(module.monitoring.loki_configs[name], "mocksecretkey")
    )])
    error_message = "Loki: ring on the HA VLAN, RF 3, S3 via 127.0.0.1:7480, ruler to mon01's Alertmanager, 90d retention, no keys in loki.yaml."
  }

  assert {
    # One VRRP instance: adverts over the HA NIC (eth5), the VIPs on the client NICs, nopreempt.
    condition = alltrue([for name, p in { log01 = { i = 33, prio = 150 }, log02 = { i = 34, prio = 100 }, log03 = { i = 35, prio = 50 } } : (
      strcontains(nonsensitive(module.monitoring.logging_deployments[name]), "put '/etc/keepalived/keepalived.conf' '0600' 'root' '' 'keepalived'") &&
      strcontains(nonsensitive(module.monitoring.logging_deployments[name]), base64encode(templatefile("../../modules/services/monitoring/templates/keepalived.conf.tftpl", {
        host          = name
        router_id     = 40
        priority      = p.prio
        auth_pass     = "mockmockmockmockmockmockmockmock" # mocked random_password
        alloy_address = "10.13.11.${p.i}"
        ha_interface  = "eth5"
        ha_address    = "10.21.12.${p.i}"
        peers         = [for j in [33, 34, 35] : "10.21.12.${j}" if j != p.i]
        vips = [
          { cidr = "10.13.11.40/16", interface = "eth2" },
          { cidr = "10.5.11.40/16", interface = "eth3" },
          { cidr = "10.20.11.40/16", interface = "eth0" },
        ]
      })))
    )])
    error_message = "keepalived: vrid 40 over eth5 (HA VLAN), VIPs on eth2/eth3/eth0, priorities 150/100/50."
  }

  assert {
    condition = (
      strcontains(module.monitoring.alloy_configs.log01, "syslog_format          = \"raw\"") &&
      strcontains(module.monitoring.alloy_configs.log01, "address                = \"0.0.0.0:1514\"") &&
      strcontains(module.monitoring.alloy_configs.log01, "url = \"http://127.0.0.1:3100/loki/api/v1/push\"") &&
      # Sender address => host, from snmp_targets (the same host label Prometheus uses).
      strcontains(module.monitoring.alloy_configs.log01, "replacement   = \"c9800-wlc-1\"") && strcontains(module.monitoring.alloy_configs.log01, "replacement   = \"m326-2\"") &&
      strcontains(module.monitoring.units.log01.alloy, "--stability.level=experimental") &&
      strcontains(module.monitoring.units.log01.alloy, "Network=host") &&
      # The other VMs ship only their journal, to the VIP.
      !strcontains(module.monitoring.alloy_configs.mon01, "loki.source.syslog") &&
      strcontains(module.monitoring.alloy_configs.graf01, "url = \"http://10.13.11.40:3100/loki/api/v1/push\"") &&
      !strcontains(module.monitoring.units.mon01.alloy, "stability.level") &&
      strcontains(module.monitoring.units.graf02.alloy, "--server.http.listen-addr=10.13.11.32:12345") &&
      contains(module.monitoring.backend_services, "alloy")
    )
    error_message = "Alloy: syslog (TCP/UDP 514, raw UDP 1514) on the logging VMs into the local Loki; journal-only on mon01/graf to the VIP."
  }

  assert {
    condition = alltrue([for name in ["log01", "log02", "log03"] : (
      strcontains(module.monitoring.haproxy_configs[name], "bind 127.0.0.1:7480") &&
      strcontains(module.monitoring.haproxy_configs[name], "server rgw1 10.27.0.12:7480") &&
      strcontains(module.monitoring.haproxy_configs[name], "server rgw3 10.27.0.17:7480") &&
      strcontains(module.monitoring.haproxy_configs[name], "http-check expect status 200")
    )])
    error_message = "haproxy balances the three PVE RGWs behind 127.0.0.1:7480, with health checks."
  }

  assert {
    condition = (
      strcontains(module.monitoring.prometheus_config, "\"job_name\": \"loki\"") &&
      strcontains(module.monitoring.prometheus_config, "10.13.11.33:3100") &&
      strcontains(module.monitoring.prometheus_config, "10.13.11.35:8405") &&
      strcontains(module.monitoring.prometheus_config, "10.13.11.30:12345") &&
      strcontains(module.monitoring.prometheus_config, "10.13.11.34:9100") &&
      strcontains(module.monitoring.units.log02["node-exporter"], "--collector.netdev.address-info") &&
      length([for g in yamldecode(module.monitoring.prometheus_rules).groups : g if g.name == "logging"]) == 1 &&
      length([for r in one([for g in yamldecode(module.monitoring.prometheus_rules).groups : g.rules if g.name == "logging"]) : r if r.alert == "LoggingVIPNotHeldOnce"]) == 3 &&
      strcontains(module.monitoring.prometheus_rules, "loki_ingester_chunks_flush_failures_total") &&
      strcontains(module.monitoring.prometheus_rules, "loki_source_syslog_entries_total")
    )
    error_message = "Prometheus scrapes Loki, haproxy, Alloy and node_exporter on the logging VMs over the backend VLAN, with logging alerts (one VIP rule per VIP)."
  }

  assert {
    condition = (
      strcontains(module.monitoring.datasources_config, "\"uid\": \"loki\"") &&
      strcontains(module.monitoring.datasources_config, "\"url\": \"http://10.13.11.40:3100\"") &&
      # $$ escapes Grafana's environment expansion of provisioning files.
      one([for d in yamldecode(module.monitoring.datasources_config).datasources : d.jsonData.derivedFields[0].url if d.uid == "loki"]) == "up{host=\"$$${__value.raw}\"}"
    )
    error_message = "Grafana gets a Loki datasource (uid loki) on the backend VIP, linking the host label to Prometheus."
  }

  assert {
    condition = alltrue([for name in ["log01", "log02", "log03"] : (
      strcontains(nonsensitive(module.monitoring.logging_deployments[name]), "-verify-config") &&
      strcontains(nonsensitive(module.monitoring.logging_deployments[name]), "validate --stability.level=experimental /etc/alloy/config.alloy") &&
      strcontains(nonsensitive(module.monitoring.logging_deployments[name]), "haproxy -c") &&
      strcontains(nonsensitive(module.monitoring.logging_deployments[name]), "for pkg in keepalived; do") &&
      strcontains(nonsensitive(module.monitoring.logging_deployments[name]), "put '/etc/logging/loki.env' '0600' 'root' 'loki' ''") &&
      strcontains(nonsensitive(module.monitoring.logging_deployments[name]), "ensure_dir '/var/lib/logging/loki' '0750' 'runtime|docker.io/grafana/loki:3.7.9'")
    )])
    error_message = "Each logging deploy.sh validates Loki/Alloy/haproxy/nftables first, installs keepalived, and keeps the S3 keys in a 0600 env file."
  }
}

run "logging_needs_s3_keys" {
  command = plan

  variables {
    loki_s3 = null
  }

  expect_failures = [terraform_data.logging]
}

run "logging_ha_nic_required" {
  command = plan

  # The logging VMs without their HA VLAN (214) NIC.
  variables {
    vms = merge(
      {
        mon01 = {
          owner              = "services-vms"
          role               = "monitoring"
          node               = "zoness"
          vm_id              = 1130
          management_address = "10.20.11.30/16"
          network_devices = [
            { bridge = "vmbr4000", vlan_id = 13, ipv4_address = "10.13.11.30/16" },
            { bridge = "vmbr100", ipv4_address = "10.5.11.30/16" },
          ]
        }
      },
      { for name, i in { log01 = 33, log02 = 34, log03 = 35 } : name => {
        owner                  = "services-vms"
        role                   = "logging"
        node                   = "zoness"
        vm_id                  = 1100 + i
        management_address     = "10.20.11.${i}/16"
        network_devices = [
          { bridge = "vmbr4000", vlan_id = 13, ipv4_address = "10.13.11.${i}/16" },
          { bridge = "vmbr100", ipv4_address = "10.5.11.${i}/16" },
        ]
      } },
    )
  }

  expect_failures = [terraform_data.logging]
}

run "grafana_ha" {
  command = plan

  assert {
    # Alerting gossip on the Grafana HA VLAN (213), published only there.
    condition = alltrue([for name, i in { graf01 = 31, graf02 = 32 } : (
      strcontains(module.monitoring.units[name].grafana, "GF_UNIFIED_ALERTING_HA_ADVERTISE_ADDRESS=10.21.11.${i}:9094") &&
      strcontains(module.monitoring.units[name].grafana, "PublishPort=10.21.11.${i}:9094:9094/udp") &&
      !strcontains(module.monitoring.units[name].grafana, "10.13.11.${i}:9094")
    )])
    error_message = "Grafana alerting HA gossips over 10.21.11.31/.32:9094."
  }

  assert {
    # VIP on the UI NIC (eth1, VLAN 2), adverts unicast on the HA NIC (eth3), router id 11.
    condition = (
      strcontains(nonsensitive(module.monitoring.grafana_keepalived_configs.graf01), "10.2.11.40/16 dev eth1") &&
      strcontains(nonsensitive(module.monitoring.grafana_keepalived_configs.graf01), "interface eth3") &&
      strcontains(nonsensitive(module.monitoring.grafana_keepalived_configs.graf01), "unicast_src_ip 10.21.11.31") &&
      strcontains(nonsensitive(module.monitoring.grafana_keepalived_configs.graf01), "    10.21.11.32\n") &&
      strcontains(nonsensitive(module.monitoring.grafana_keepalived_configs.graf01), "priority 150") &&
      strcontains(nonsensitive(module.monitoring.grafana_keepalived_configs.graf02), "priority 100") &&
      strcontains(nonsensitive(module.monitoring.grafana_keepalived_configs.graf02), "virtual_router_id 11")
    )
    error_message = "keepalived on graf01/02: VIP 10.2.11.40 on eth1, unicast adverts over eth3, vrid 11, name-ordered priority."
  }
}

run "grafana_vrrp_disabled" {
  command = plan
  variables { grafana_vrrp = null }

  assert {
    condition     = nonsensitive(module.monitoring.grafana_keepalived_configs.graf01) == null
    error_message = "grafana_vrrp = null renders no keepalived config."
  }
}
