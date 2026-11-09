mock_provider "random" {
  mock_resource "random_password" {
    defaults = { result = "mockmockmockmockmockmockmockmock" }
  }
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
      strcontains(module.monitoring.units.graf01.grafana, "GF_UNIFIED_ALERTING_HA_PEERS=10.13.11.31:9094,10.13.11.32:9094") &&
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
        "Hosts/node-exporter-full.json"        = "node-exporter-full"
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
    condition = alltrue([for rel, content in module.monitoring.dashboards : (
      (strcontains(content, "{\"type\":\"prometheus\",\"uid\":\"prometheus\"}") ||
      (startswith(rel, "Proxmox/") && strcontains(content, "{\"type\":\"influxdb\",\"uid\":\"influxdb\"}"))) &&
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
      strcontains(nonsensitive(module.monitoring.grafana_deployments[name]), "put '/etc/grafana-container/provisioning/dashboards/files/Network/snmp-device-summary.json' '0644' 'root' '' ''") &&
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
