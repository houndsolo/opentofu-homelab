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

override_resource {
  target = random_password.pg_vrrp
  values = { result = "pgvrrp01" }
}

override_resource {
  target = random_password.backend_vrrp
  values = { result = "monvrrp1" }
}

mock_provider "proxmox" {}

mock_provider "proxmox" {
  alias = "greatfox"
}

variables {
  ssh_private_key_path = "/dev/null"
  pve_api_token        = "mock@pve!mock=00000000-0000-0000-0000-000000000000"
  greatfox_api_token   = "mock@pve!mock=00000000-0000-0000-0000-000000000000"
  postgres_settings    = {} # the default; postgres.auto.tfvars (the live cutover) would leak in
  loki_s3              = { bucket = "loki", access_key = "MOCKACCESSKEY", secret_key = "mocksecretkeymocksecretkey" }
  mimir_s3             = { bucket = "mimir", access_key = "MOCKMIMIRKEY", secret_key = "mockmimirsecretmockmimirsecret" } # metrics.tftest.hcl
  postgres_s3          = { bucket = "postgres", access_key = "MOCKPGKEY", secret_key = "mockpgsecretmockpgsecret" }       # postgres.tftest.hcl
}

run "inventory_targets" {
  command = plan

  assert {
    condition = (
      output.prometheus_url == "http://10.5.11.30:9090" &&
      output.grafana_urls == { graf01 = "http://10.52.11.32:3000", graf02 = "http://10.52.11.33:3000" } &&
      length(terraform_data.backend) == 2 && length(terraform_data.grafana) == 2
    )
    error_message = "Deploy both backends (mon01, mon02) and both Grafana VMs, with UIs on the expected addresses."
  }

  assert {
    condition = (
      strcontains(module.monitoring.prometheus_config, "10.5.1.11:9100") &&    # PVE node on vmbr100
      strcontains(module.monitoring.prometheus_config, "10.55.11.32:9100") &&  # Grafana over lylat-telemetry
      strcontains(module.monitoring.prometheus_config, "10.20.10.17:9342") &&  # leaf FRR exporter
      strcontains(module.monitoring.prometheus_config, "10.20.10.255:9100") && # fw-wan extra target
      strcontains(module.monitoring.prometheus_config, "\"snmp-spines\"") &&
      strcontains(module.monitoring.prometheus_config, "10.8.53.1") && # DNS SOA probe on the service address
      !strcontains(module.monitoring.prometheus_config, "\"/pve\"") && # no pve job without a token
      # VM jobs: instance = <host>:<port> (stable across address moves); device jobs keep theirs.
      one([for j in yamldecode(module.monitoring.prometheus_config).scrape_configs : j if j.job_name == "node"]).relabel_configs[0].replacement == "$1:$2" &&
      length(try(one([for j in yamldecode(module.monitoring.prometheus_config).scrape_configs : j if j.job_name == "vyos-frr"]).relabel_configs, [])) == 0
    )
    error_message = "Scrape targets must come from the inventory, and pve must be absent without a token."
  }

  assert {
    condition = (
      strcontains(module.monitoring.datasources_config, "http://10.54.16.30:9090") &&
      !contains(module.monitoring.backend_services, "pve-exporter")
    )
    error_message = "Grafana datasources use the backend VLAN."
  }

  assert {
    condition = (
      strcontains(nonsensitive(module.monitoring.backend_deployments.mon01), "promtool") &&
      strcontains(module.monitoring.units.mon01.postgres, "PublishPort=10.54.16.30:5432:5432\n") &&
      !strcontains(module.monitoring.units.mon01.postgres, "10.5.11.30") &&
      strcontains(module.monitoring.units.graf01.grafana, "GF_UNIFIED_ALERTING_HA_PEERS=10.50.11.32:9094,10.50.11.33:9094") &&
      strcontains(module.monitoring.units.graf02["node-exporter"], "--web.listen-address=10.55.11.33:9100") &&
      strcontains(module.monitoring.units.mon01.prometheus, "ExecReload=/usr/bin/podman kill --signal HUP prometheus") &&
      # The data dir of an image that drops from root to a service user stays owned by that user,
      # so a redeploy that doesn't restart Postgres can't lock it out.
      strcontains(nonsensitive(module.monitoring.backend_deployments.mon01), "ensure_dir '/var/lib/monitoring/postgres' '0700' 'user|docker.io/library/postgres:17|postgres'")
    )
    error_message = "Validate before install, bind Postgres to the backend VLAN only, and peer Grafana over it."
  }

  assert {
    condition = (
      strcontains(module.monitoring.dashboard_providers_config, "\"path\": \"/etc/grafana/provisioning/dashboards/files\"") &&
      strcontains(module.monitoring.dashboard_providers_config, "\"foldersFromFilesStructure\": true") &&
      strcontains(module.monitoring.dashboard_providers_config, "\"allowUiUpdates\": false") &&
      { for rel, content in module.monitoring.dashboards : rel => jsondecode(content).uid } == {
        "Databases/postgres-cluster.json"                  = "postgres-cluster"
        "Databases/postgres-instance.json"                 = "postgres-instance"
        "Databases/prometheus.json"                        = "prometheus-server"
        "Databases/mimir.json"                             = "mimir"
        "Databases/loki.json"                              = "loki"
        "Databases/telegraf.json"                          = "telegraf"
        "Databases/valkey.json"                            = "valkey"
        "Edge/fw-wan-firewall.json"                        = "fw-wan-firewall"
        "Edge/fw-wan-overview.json"                        = "fw-wan-overview"
        "Edge/fw-wan-routing.json"                         = "fw-wan-routing"
        "Edge/fw-wan-vpn.json"                             = "fw-wan-vpn"
        "Hosts/node-exporter-full.json"                    = "node-exporter-full"
        "Logs/fw-wan-logs.json"                            = "logs-fw-wan"
        "Logs/logs-overview.json"                          = "logs-overview"
        "Logs/network-device-logs.json"                    = "logs-network"
        "Logs/proxmox-ceph-logs.json"                      = "logs-proxmox"
        "Logs/services-logs.json"                          = "logs-services"
        "Monitoring/monitoring-stack.json"                 = "monitoring-stack"
        "Network/frr-evpn-fabric.json"                     = "frr-evpn-fabric"
        "Network/mikrotik-snmp.json"                       = "mikrotik-snmp"
        "Network/snmp-device-summary.json"                 = "snmp-device-summary"
        "Network/snmp-interface-detail.json"               = "snmp-interface-detail"
        "Network/snmp-interface-throughput-community.json" = "snmp-throughput-community"
        "Network/snmp-throughput.json"                     = "snmp-throughput"
        "Network/wireless-client.json"                     = "wireless-client"
        "Network/wireless-overview.json"                   = "wireless-overview"
        "Overview/overview.json"                           = "lylat-overview"
        "Probes/blackbox-probes.json"                      = "blackbox-probes"
        "Proxmox/proxmox-guest.json"                       = "proxmox-guest"
        "Proxmox/proxmox-node.json"                        = "proxmox-node"
        "Proxmox/proxmox-overview.json"                    = "proxmox-overview"
        "Proxmox/proxmox-storage.json"                     = "proxmox-storage"
        "Services/dark-triage.json"                        = "dark-triage"
        "Services/dns-bind.json"                           = "dns-bind"
        "Services/nginx-proxy.json"                        = "nginx-proxy"
        "Storage/ceph-cluster.json"                        = "ceph-cluster"
        "Storage/ceph-osd.json"                            = "ceph-osd"
        "Storage/ceph-rgw-buckets.json"                    = "ceph-rgw-buckets"
        "Storage/ceph-cluster-advanced.json"               = "ceph-cluster-advanced"
        "Storage/ceph-filesystem.json"                     = "ceph-filesystem"
        "Storage/ceph-osd-device-details.json"             = "ceph-osd-device-details"
        "Storage/ceph-osds-overview.json"                  = "ceph-osds-overview"
        "Storage/ceph-pool-details.json"                   = "ceph-pool-details"
        "Storage/ceph-pools-overview.json"                 = "ceph-pools-overview"
        "Storage/ceph-rbd-details.json"                    = "ceph-rbd-details"
        "Storage/ceph-rbd-overview.json"                   = "ceph-rbd-overview"
      }
    )
    error_message = "Provision the dashboards from dashboards/<Folder>/*.json, with fixed uids, through a file provider that the UI can't save over."
  }

  assert {
    # Every dashboard carries the lylat tag and its folder's category tag (lylat-<folder>). Every
    # dashboard but the overview has one "Dashboards" dropdown (tag lylat); the overview instead has
    # one dropdown per category folder (tag lylat-<category>), and every non-overview folder is one
    # of those categories, so no dashboard is missing from the overview.
    condition = alltrue([for rel, content in module.monitoring.dashboards : (
      contains(jsondecode(content).tags, "lylat") &&
      contains(jsondecode(content).tags, "lylat-${lower(split("/", rel)[0])}") &&
      (rel == "Overview/overview.json" ||
      length([for l in jsondecode(content).links : l if l.type == "dashboards" && l.tags == ["lylat"]]) == 1)
      )]) && alltrue([
      for l in jsondecode(module.monitoring.dashboards["Overview/overview.json"]).links :
      l.asDropdown && length(l.tags) == 1 && startswith(l.tags[0], "lylat-") if l.type == "dashboards"
      ]) && length([
      for l in jsondecode(module.monitoring.dashboards["Overview/overview.json"]).links : l if l.type == "dashboards" && l.tags == ["lylat"]
      ]) == 0 && alltrue([
      for rel in keys(module.monitoring.dashboards) :
      contains([for l in jsondecode(module.monitoring.dashboards["Overview/overview.json"]).links : l.tags[0] if l.type == "dashboards"], "lylat-${lower(split("/", rel)[0])}")
      if split("/", rel)[0] != "Overview"
    ])
    error_message = "Every dashboard carries lylat + lylat-<folder> and a Dashboards dropdown; the overview has one dropdown per category folder, covering every folder."
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
    # The log dashboards (Logs/) read Loki.
    condition = alltrue([for rel, content in module.monitoring.dashboards : (
      (
        strcontains(content, "{\"type\":\"prometheus\",\"uid\":\"prometheus\"}") ||
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
    # The Proxmox dashboards read pvestatd's series (job pvestatd) from the Prometheus datasource, no
    # InfluxDB or Flux left, pick the cluster (lylat or greatfox) and share a "Proxmox dashboards" dropdown.
    condition = alltrue([for rel, content in module.monitoring.dashboards : (
      contains(jsondecode(content).tags, "proxmox") &&
      length([for l in jsondecode(content).links : l if l.type == "dashboards" && contains(l.tags, "proxmox")]) == 1 &&
      strcontains(content, "pvestatd_") &&
      !strcontains(content, "influx") && !strcontains(content, "from(bucket") &&
      length([for v in jsondecode(content).templating.list : v if v.name == "cluster" && v.type == "custom" && v.query == "lylat cluster : !=,greatfox : ="]) == 1
    ) if startswith(rel, "Proxmox/")])
    error_message = "Proxmox dashboards carry the proxmox tag and dropdown, read pvestatd_* from Prometheus (no InfluxDB/Flux) and offer the cluster picker."
  }

  assert {
    # The wireless dashboards read the C9800 telemetry's wlc_* series (job wlc) from the Prometheus datasource,
    # no InfluxDB or Flux left, pick WLCs by the series' host label and share a "Wireless dashboards" dropdown.
    condition = alltrue([for rel, content in module.monitoring.dashboards : (
      contains(jsondecode(content).tags, "wireless") &&
      length([for l in jsondecode(content).links : l if l.type == "dashboards" && contains(l.tags, "wireless")]) == 1 &&
      strcontains(content, "wlc_") &&
      !strcontains(content, "influx") && !strcontains(content, "from(bucket") &&
      length([for v in jsondecode(content).templating.list : v if v.name == "wlc" && v.definition == "label_values(wlc_cpu_five_seconds, host)"]) == 1
    ) if startswith(rel, "Network/wireless-")]) && length([for rel in keys(module.monitoring.dashboards) : rel if startswith(rel, "Network/wireless-")]) == 2
    error_message = "Wireless dashboards carry the wireless tag and dropdown, read wlc_* from Prometheus (no InfluxDB/Flux) and pick WLCs by host."
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
    )]) && !strcontains(nonsensitive(module.monitoring.backend_deployments.mon01), "\nprune '")
    error_message = "Grafana VMs install the dashboards without a restart (the provider polls), restart only for the provider file, and prune removed dashboards."
  }
}

# node_exporter collectors, the exporters' self-scrapes and the ceph-mixin alerts (main.tf),
# the retired InfluxDB relay's and InfluxDB's cleanup (backends.tf).
run "exporters_and_ceph_alerts" {
  command = plan

  assert {
    # The same extra collectors (and the D-Bus socket for systemd) on every VM's node_exporter.
    condition = alltrue([for name in ["mon01", "mon02", "graf01", "graf02", "loki01", "mim01"] : (
      strcontains(module.monitoring.units[name]["node-exporter"], " --collector.processes --collector.tcpstat --collector.interrupts --collector.systemd --collector.systemd.unit-include=.+[.](service|socket|timer)\n") &&
      strcontains(module.monitoring.units[name]["node-exporter"], "Volume=/run/dbus/system_bus_socket:/var/run/dbus/system_bus_socket:ro\n")
    )])
    error_message = "node_exporter on every VM runs the processes, tcpstat, interrupts and systemd collectors (services/sockets/timers), with the host's D-Bus socket."
  }

  assert {
    # Each replica scrapes both backends' exporters, so Mimir (one replica's samples) sees both.
    condition = alltrue([for job, port in { snmp-exporter = 9116, blackbox-exporter = 9115 } : (
      one([for j in yamldecode(module.monitoring.prometheus_config).scrape_configs : j.static_configs if j.job_name == job]) == [
        { targets = ["10.54.16.30:${port}"], labels = { host = "mon01" } },
        { targets = ["10.54.16.31:${port}"], labels = { host = "mon02" } },
      ] &&
      strcontains(module.monitoring.units.mon01[job], "PublishPort=10.54.16.30:${port}:${port}\n") &&
      strcontains(module.monitoring.units.mon02[job], "PublishPort=10.54.16.31:${port}:${port}\n")
    )])
    error_message = "The snmp/blackbox exporters are published on the backend VLAN and scraped there from both replicas, with host = backend."
  }

  assert {
    # Every scrape target carries a host label (the monitoring-stack dashboard groups by it).
    condition     = alltrue(flatten([for j in yamldecode(module.monitoring.prometheus_config).scrape_configs : [for sc in try(j.static_configs, []) : try(sc.labels.host, "") != ""]]))
    error_message = "Every static scrape target has a host label."
  }

  assert {
    # pvestatd -> Telegraf -> Prometheus: a Telegraf per backend takes the PVE metric servers' writes on the
    # monitoring network (token from the env file, never in the config), each Prometheus scrapes its own
    # one by container name every 10 s, and every backend gets its own metric server on the cluster.
    condition = (
      alltrue([for name, addr in { mon01 = "10.5.11.30", mon02 = "10.5.11.31" } : (
        strcontains(module.monitoring.units[name].pvestatd, "PublishPort=${addr}:8186:8186\n") &&
        strcontains(module.monitoring.units[name].pvestatd, "EnvironmentFile=/etc/monitoring/pvestatd.env\n") &&
        strcontains(nonsensitive(module.monitoring.backend_deployments[name]), "put '/etc/monitoring/pvestatd.env' '0600' 'root' 'pvestatd' ''") &&
        proxmox_metrics_server.pvestatd[name].server == addr && proxmox_metrics_server.pvestatd[name].port == 8186
      )]) &&
      strcontains(module.monitoring.pvestatd_telegraf_config, "token = \"$${PVESTATD_TOKEN}\"") &&
      strcontains(module.monitoring.pvestatd_telegraf_config, "string_as_label = false") &&
      strcontains(module.monitoring.pvestatd_telegraf_config, "sep.join(sorted(") && # tags/content in a fixed order
      one([for j in yamldecode(module.monitoring.prometheus_config).scrape_configs : j if j.job_name == "pvestatd"]).scrape_interval == "10s" &&
      one([for j in yamldecode(module.monitoring.prometheus_config).scrape_configs : j if j.job_name == "pvestatd"]).static_configs[0].targets == ["pvestatd:9274"] &&
      strcontains(module.monitoring.prometheus_rules, "PveMetricsStopped")
    )
    error_message = "pvestatd: a Telegraf per backend on :8186, scraped locally every 10 s, one PVE metric server per backend."
  }

  assert {
    # The InfluxDB relay is retired: no unit, scrape job or alerts, and the deploy removes its files.
    condition = (
      !contains([for j in yamldecode(module.monitoring.prometheus_config).scrape_configs : j.job_name], "influx-relay") &&
      !strcontains(module.monitoring.prometheus_rules, "InfluxRelay") &&
      alltrue([for name in ["mon01", "mon02"] : (
        !contains(keys(module.monitoring.units[name]), "influx-relay") &&
        !strcontains(nonsensitive(module.monitoring.backend_deployments[name]), ":8087") &&
        strcontains(nonsensitive(module.monitoring.backend_deployments[name]), "rm -rf /etc/monitoring/influx-relay /etc/monitoring/influx-relay.env;")
      )])
    )
    error_message = "No influx-relay unit, scrape job or alerts; the backend deploy removes its config dir and env file."
  }

  assert {
    # InfluxDB is retired (2026-11-14): no unit, image, scrape job, datasource, keepalived check or token; Grafana
    # deletes the old datasource; the backend deploy removes the env files with its tokens but keeps the data.
    condition = (
      !contains([for j in yamldecode(module.monitoring.prometheus_config).scrape_configs : j.job_name], "influxdb") &&
      !strcontains(module.monitoring.prometheus_config, ":8086") &&
      !contains([for d in yamldecode(module.monitoring.datasources_config).datasources : d.uid], "influxdb") &&
      yamldecode(module.monitoring.datasources_config).deleteDatasources == [{ name = "InfluxDB", orgId = 1 }] &&
      alltrue([for name in ["mon01", "mon02"] : (
        !contains(keys(module.monitoring.units[name]), "influxdb") &&
        !contains(module.monitoring.backend_services_by_host[name], "influxdb") &&
        !strcontains(nonsensitive(module.monitoring.backend_deployments[name]), "docker.io/library/influxdb") &&
        !strcontains(nonsensitive(module.monitoring.backend_deployments[name]), ":8086") &&
        !strcontains(nonsensitive(module.monitoring.backend_deployments[name]), "ensure_dir '/var/lib/monitoring/influxdb") &&
        !strcontains(nonsensitive(module.monitoring.backend_deployments[name]), "rm -rf /var/lib/monitoring/influxdb") &&
        strcontains(nonsensitive(module.monitoring.backend_deployments[name]), "rm -f /etc/monitoring/influxdb.env /etc/monitoring/telegraf.env;") &&
        !strcontains(nonsensitive(module.monitoring.backend_keepalived_configs[name]), "8086") &&
        !strcontains(module.monitoring.units[name].telegraf, "EnvironmentFile=")
      )])
    )
    error_message = "InfluxDB is gone from the backends, Prometheus, Grafana and keepalived; the deploy removes its env files and keeps its data."
  }

  assert {
    # Local Prometheus keeps a week; Mimir has the long-term copy.
    condition = alltrue([for name in ["mon01", "mon02"] : (
      strcontains(module.monitoring.units[name].prometheus, "--storage.tsdb.retention.time=7d") &&
      strcontains(module.monitoring.units[name].prometheus, "--storage.tsdb.retention.size=20GB")
    )])
    error_message = "Prometheus on the backends keeps 7d / 20GB locally."
  }

  assert {
    # The vendored ceph-mixin alerts, minus the 4 groups that reference metrics
    # which don't exist on a non-cephadm (PVE) cluster (DT-039).
    condition = (
      length(yamldecode(module.monitoring.prometheus_ceph_rules).groups) == 12 &&
      length(flatten([for g in yamldecode(module.monitoring.prometheus_ceph_rules).groups : g.rules])) == 56 &&
      contains(flatten([for g in yamldecode(module.monitoring.prometheus_ceph_rules).groups : [for r in g.rules : r.alert]]), "CephHealthWarning") &&
      contains(flatten([for g in yamldecode(module.monitoring.prometheus_ceph_rules).groups : [for r in g.rules : r.alert]]), "CephFilesystemOffline") &&
      alltrue([for name in ["mon01", "mon02"] : (
        strcontains(nonsensitive(module.monitoring.backend_deployments[name]), "unpack '/etc/monitoring/prometheus/rules/ceph.yml' '${base64encode(module.monitoring.prometheus_ceph_rules)}'") &&
        strcontains(nonsensitive(module.monitoring.backend_deployments[name]), "check rules /etc/prometheus/rules/ceph.yml")
      )])
    )
    error_message = "Both backends load the ceph-mixin's alert rules as rules/ceph.yml (hardware/nvmeof/rbdmirror/cephadm groups skipped) and check them with promtool."
  }

  assert {
    # Only the "nodes" group changes: its node_* selectors are limited to the PVE cluster's nodes.
    condition = (
      one([for g in yamldecode(module.monitoring.prometheus_ceph_rules).groups : { for r in g.rules : r.alert => r.expr } if g.name == "nodes"])["CephNodeRootFilesystemFull"] == "node_filesystem_avail_bytes{host=~\"eldarad|fichina|fortuna|macbeth|titania|venom|zoness\",mountpoint=\"/\"} / node_filesystem_size_bytes{host=~\"eldarad|fichina|fortuna|macbeth|titania|venom|zoness\",mountpoint=\"/\"} * 100 < 5" &&
      startswith(one([for g in yamldecode(module.monitoring.prometheus_ceph_rules).groups : { for r in g.rules : r.alert => r.expr } if g.name == "nodes"])["CephNodeInconsistentMTU"], "node_network_mtu_bytes{host=~\"eldarad|fichina|fortuna|macbeth|titania|venom|zoness\"} * (node_network_up{host=~\"eldarad|fichina|fortuna|macbeth|titania|venom|zoness\",device!=\"lo\"} > 0)") &&
      alltrue([for r in one([for g in yamldecode(module.monitoring.prometheus_ceph_rules).groups : g.rules if g.name == "nodes"]) : length(regexall("\\bnode_[a-z_]+", r.expr)) == length(regexall("\\bnode_[a-z_]+\\{host=~", r.expr))]) &&
      [for g in yamldecode(module.monitoring.prometheus_ceph_rules).groups : g.rules if g.name == "cluster health"] == [for g in yamldecode(file("../../modules/services/monitoring/rules/ceph-mixin/prometheus_alerts.yml")).groups : g.rules if g.name == "cluster health"]
    )
    error_message = "The ceph-mixin's node_* alerts are limited to the PVE cluster's nodes; the other groups are loaded unchanged."
  }
}

run "ceph_alerts_need_ceph" {
  command = plan

  variables {
    ceph_mgr_nodes = []
  }

  assert {
    condition = (
      module.monitoring.prometheus_ceph_rules == "" &&
      !strcontains(nonsensitive(module.monitoring.backend_deployments.mon01), "rules/ceph.yml")
    )
    error_message = "Without Ceph targets there are no ceph-mixin alerts."
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
      strcontains(nonsensitive(module.monitoring.backend_deployments.mon01), "--dry-run")
    )
    error_message = "SNMPv3 auths add a second exporter config file, validated before install, and the WLC job uses them."
  }

  assert {
    condition     = !strcontains(module.monitoring.prometheus_config, "authsecret123") && !strcontains(module.monitoring.units.mon01["snmp-exporter"], "authsecret123")
    error_message = "SNMPv3 secrets must not end up in prometheus.yml or the unit."
  }
}

# The MikroTik jobs walk mikrotik_lite, a slim copy of the bundled mikrotik module (DT-023).
run "snmp_mikrotik_lite" {
  command = plan

  assert {
    condition = (
      strcontains(module.monitoring.units.mon01["snmp-exporter"], "Volume=/etc/monitoring/snmp-exporter/mikrotik_lite.yml:/etc/snmp_exporter/mikrotik_lite.yml:ro") &&
      strcontains(module.monitoring.units.mon01["snmp-exporter"], "--config.file=/etc/snmp_exporter/snmp.yml --config.file=/etc/snmp_exporter/mikrotik_lite.yml") &&
      strcontains(nonsensitive(module.monitoring.backend_deployments.mon01), "--config.file=/etc/snmp_exporter/mikrotik_lite.yml") &&
      strcontains(nonsensitive(module.monitoring.backend_deployments.mon01), "--dry-run")
    )
    error_message = "The exporter loads mikrotik_lite.yml next to the bundled snmp.yml, and the deploy dry-runs that set (DT-023)."
  }

  assert {
    condition     = !strcontains(module.monitoring.prometheus_config, "- \"mikrotik\"\n")
    error_message = "No job walks the bundled mikrotik module (the whole MIKROTIK-MIB); use mikrotik_lite."
  }
}

# The MikroTik SNMP jobs get a longer timeout (their walks take 8-10 s); the others keep the global one.
run "snmp_scrape_timeouts" {
  command = plan

  assert {
    condition = (
      strcontains(module.monitoring.prometheus_config, "\"job_name\": \"snmp-spines\"\n  \"metrics_path\": \"/snmp\"") &&
      length(regexall("\"scrape_timeout\": \"20s\"", module.monitoring.prometheus_config)) == 2 &&
      length(regexall("\"scrape_interval\": \"30s\"\n  \"scrape_timeout\": \"20s\"", module.monitoring.prometheus_config)) == 2
    )
    error_message = "snmp-mikrotik-access and snmp-spines scrape every 30s with a 20s timeout."
  }

  # HOST-RESOURCES-MIB is its own fast job, so the slow walks timing out don't take it along.
  assert {
    condition = (
      strcontains(module.monitoring.prometheus_config, "\"job_name\": \"snmp-mikrotik-hr\"\n  \"metrics_path\": \"/snmp\"\n  \"params\":\n    \"auth\":\n    - \"public_v2\"\n    \"module\":\n    - \"hrDevice\"\n    - \"hrStorage\"\n    - \"hrSystem\"\n  \"relabel_configs\"") &&
      strcontains(module.monitoring.prometheus_config, "\"job_name\": \"snmp-spines\"\n  \"metrics_path\": \"/snmp\"\n  \"params\":\n    \"auth\":\n    - \"public_v2\"\n    \"module\":\n    - \"if_mib\"\n    - \"mikrotik_lite\"\n    - \"system\"\n  \"relabel_configs\"") &&
      length(regexall("\"targets\":\n    - \"10\\.5\\.0\\.[3-6]\"", module.monitoring.prometheus_config)) == 8
    )
    error_message = "snmp-mikrotik-hr walks hrDevice/hrStorage/hrSystem on the 4 MikroTiks (global interval and timeout); the slow jobs walk if_mib/mikrotik_lite/system."
  }
}

run "pve_metric_servers" {
  command = plan

  assert {
    condition = (
      # pvestatd writes only to the pvestatd Telegrafs: one metric server per backend, on the cluster and on greatfox.
      toset(keys(proxmox_metrics_server.pvestatd)) == toset(["mon01", "mon02"]) &&
      toset(keys(proxmox_metrics_server.pvestatd_standalone)) == toset(["greatfox/mon01", "greatfox/mon02"]) &&
      alltrue([for s in values(proxmox_metrics_server.pvestatd) : s.port == 8186 && s.influx_db_proto == "http" && !s.disable && s.influx_organization == "lylat"])
    )
    error_message = "The cluster and greatfox each push over HTTP to every backend's pvestatd Telegraf."
  }
}

run "wlc_telemetry" {
  command = plan

  assert {
    condition = (
      output.wlc_telemetry_receiver == { address = "10.5.11.102", receivers = { mon01 = "10.5.11.30", mon02 = "10.5.11.31" }, port = 57500 } &&
      module.monitoring.backend_services == ["monitoring-network", "postgres", "telegraf", "pvestatd", "snmp-exporter", "blackbox-exporter", "alertmanager", "prometheus", "node-exporter", "alloy", "keepalived"]
    )
    error_message = "The WLCs send to the monitoring VIP; Telegraf runs on both backends and starts first after Postgres."
  }

  assert {
    condition = alltrue([for name, addr in { mon01 = "30", mon02 = "31" } : (
      strcontains(module.monitoring.units[name].telegraf, "PublishPort=10.5.11.${addr}:57500:57500\n") &&
      strcontains(module.monitoring.units[name].telegraf, "PublishPort=10.5.11.102:57500:57500\n") &&
      strcontains(module.monitoring.units[name].telegraf, "PublishPort=10.54.16.${addr}:9273:9273\n") && # its own metrics, for both replicas
      !strcontains(module.monitoring.units[name].telegraf, "PublishPort=10.54.16.${addr}:57500") &&
      strcontains(module.monitoring.units[name].telegraf, "Network=monitoring.network\n") &&
      strcontains(module.monitoring.units[name].telegraf, "User=telegraf\n") &&
      strcontains(module.monitoring.units[name].telegraf, "ExecReload=/usr/bin/podman kill --signal HUP telegraf\n") &&
      # Prometheus only: no InfluxDB output, token or env file.
      !strcontains(module.monitoring.wlc_telegraf_configs[name], "influxdb") &&
      !strcontains(module.monitoring.wlc_telegraf_configs[name], "token") &&
      !strcontains(nonsensitive(module.monitoring.backend_deployments[name]), "put '/etc/monitoring/telegraf.env'") &&
      length(regexall("\\[\\[outputs\\.", module.monitoring.wlc_telegraf_configs[name])) == 2
    )])
    error_message = "Telegraf publishes the MDT port on each monitoring address and the VIP (metrics on the backend VLAN), runs as its own user and writes only to its two prometheus_client outputs."
  }

  assert {
    condition = (
      strcontains(nonsensitive(module.monitoring.backend_deployments.mon01), "put '/etc/monitoring/telegraf/telegraf.conf' '0644' 'root' '' 'telegraf'") &&
      strcontains(nonsensitive(module.monitoring.backend_deployments.mon01), "config check --config /etc/telegraf/telegraf.conf") &&
      strcontains(nonsensitive(module.monitoring.backend_deployments.mon01), "--http2-prior-knowledge http://10.5.11.30:57500/")
    )
    error_message = "deploy.sh checks the Telegraf config before install and health-checks the gRPC port."
  }

  assert {
    # keepalived holds the monitoring VIP (the WLCs' receiver) only where the WLC Telegraf answers.
    condition = alltrue([for name, addr in { mon01 = "30", mon02 = "31" } : (
      strcontains(nonsensitive(module.monitoring.backend_keepalived_configs[name]), "vrrp_script chk_telegraf {\n  script \"/usr/bin/curl -fsS -m 2 -o /dev/null http://10.54.16.${addr}:9273/metrics\"") &&
      strcontains(nonsensitive(module.monitoring.backend_keepalived_configs[name]), "track_script {\n    chk_telegraf\n    chk_alertmanager\n  }") &&
      !strcontains(nonsensitive(module.monitoring.backend_keepalived_configs[name]), "influx")
    )])
    error_message = "keepalived tracks the WLC Telegraf and Alertmanager on each backend."
  }

  assert {
    condition = (
      strcontains(module.monitoring.prometheus_config, "\"job_name\": \"telegraf\"") &&
      strcontains(module.monitoring.prometheus_config, "10.54.16.30:9273") &&
      strcontains(module.monitoring.prometheus_config, "10.54.16.31:9273") &&
      strcontains(module.monitoring.prometheus_rules, "WlcTelemetryStopped")
    )
    error_message = "Prometheus scrapes both Telegrafs' own metrics and alerts when the WLCs stop sending."
  }
}

run "wlc_telemetry_disabled" {
  command = plan

  variables {
    wlc_telemetry = null
  }

  assert {
    condition = (
      output.wlc_telemetry_receiver == null &&
      !contains(module.monitoring.backend_services, "telegraf") &&
      !contains(keys(module.monitoring.units.mon01), "telegraf") &&
      !strcontains(module.monitoring.prometheus_config, "\"job_name\": \"telegraf\"") &&
      !strcontains(nonsensitive(module.monitoring.backend_deployments.mon01), "/etc/monitoring/telegraf/") &&
      # Without it keepalived tracks Alertmanager only.
      !strcontains(nonsensitive(module.monitoring.backend_keepalived_configs.mon01), "chk_telegraf")
    )
    error_message = "wlc_telemetry = null leaves Telegraf, its scrape job and its keepalived check out."
  }
}

run "logging" {
  command = plan

  assert {
    condition = (
      length(terraform_data.logging) == 3 &&
      output.loki_url == "http://10.54.18.101:3100" &&
      output.loki_urls == { loki01 = "http://10.54.18.34:3100", loki02 = "http://10.54.18.35:3100", loki03 = "http://10.54.18.36:3100" }
    )
    error_message = "Deploy Loki on loki01-03, reached through the backend VIP."
  }

  assert {
    # The ring (memberlist, ingester gRPC) runs on the HA VLAN; S3 goes through the local haproxy.
    condition = alltrue([for name, i in { loki01 = 34, loki02 = 35, loki03 = 36 } : (
      yamldecode(module.monitoring.loki_configs[name]).common.instance_addr == "10.50.18.${i}" &&
      yamldecode(module.monitoring.loki_configs[name]).memberlist.advertise_addr == "10.50.18.${i}" &&
      yamldecode(module.monitoring.loki_configs[name]).memberlist.join_members == ["10.50.18.34:7946", "10.50.18.35:7946", "10.50.18.36:7946"] &&
      yamldecode(module.monitoring.loki_configs[name]).common.replication_factor == 3 &&
      yamldecode(module.monitoring.loki_configs[name]).common.storage.s3.endpoint == "127.0.0.1:7480" &&
      yamldecode(module.monitoring.loki_configs[name]).common.storage.s3.bucketnames == "loki" &&
      yamldecode(module.monitoring.loki_configs[name]).ruler.alertmanager_url == "http://10.54.16.30:9093,http://10.54.16.31:9093" &&
      yamldecode(module.monitoring.loki_configs[name]).limits_config.retention_period == "90d" &&
      yamldecode(module.monitoring.loki_configs[name]).compactor.retention_enabled &&
      yamldecode(module.monitoring.loki_configs[name]).schema_config.configs[0].schema == "v13" &&
      !strcontains(module.monitoring.loki_configs[name], "MOCKACCESSKEY") &&
      !strcontains(module.monitoring.loki_configs[name], "mocksecretkey")
    )])
    error_message = "Loki: ring on the HA VLAN, RF 3, S3 via 127.0.0.1:7480, ruler to both Alertmanagers, 90d retention, no keys in loki.yaml."
  }

  assert {
    # One VRRP instance: adverts over the HA NIC (eth4), the VIPs on the client NICs, nopreempt.
    condition = alltrue([for name, p in { loki01 = { i = 34, prio = 150 }, loki02 = { i = 35, prio = 100 }, loki03 = { i = 36, prio = 50 } } : (
      strcontains(nonsensitive(module.monitoring.logging_deployments[name]), "put '/etc/keepalived/keepalived.conf' '0600' 'root' '' 'keepalived'") &&
      strcontains(nonsensitive(module.monitoring.logging_deployments[name]), base64encode(templatefile("../../modules/services/monitoring/templates/keepalived.conf.tftpl", {
        host          = name
        router_id     = 101
        priority      = p.prio
        auth_pass     = "mockmockmockmockmockmockmockmock" # mocked random_password
        alloy_address = "10.55.18.${p.i}"
        ha_interface  = "eth4"
        ha_address    = "10.50.18.${p.i}"
        peers         = [for j in [34, 35, 36] : "10.50.18.${j}" if j != p.i]
        vips = [
          { cidr = "10.54.18.101/16", interface = "eth1" },
          { cidr = "10.5.11.101/16", interface = "eth2" },
          { cidr = "10.55.18.101/16", interface = "eth5" },
        ]
      })))
    )])
    error_message = "keepalived: vrid 101 over eth4 (HA VLAN), VIPs on eth1/eth2/eth5 (backend, monitoring, telemetry; none on mgmt), priorities 150/100/50."
  }

  assert {
    condition = (
      strcontains(module.monitoring.alloy_configs.loki01, "syslog_format          = \"raw\"") &&
      strcontains(module.monitoring.alloy_configs.loki01, "address                = \"0.0.0.0:1514\"") &&
      strcontains(module.monitoring.alloy_configs.loki01, "url = \"http://127.0.0.1:3100/loki/api/v1/push\"") &&
      # Sender address => host, from snmp_targets (the same host label Prometheus uses).
      strcontains(module.monitoring.alloy_configs.loki01, "replacement   = \"c9800-wlc-1\"") && strcontains(module.monitoring.alloy_configs.loki01, "replacement   = \"m326-2\"") &&
      strcontains(module.monitoring.units.loki01.alloy, "--stability.level=experimental") &&
      strcontains(module.monitoring.units.loki01.alloy, "Network=host") &&
      # The other VMs ship only their journal, to the VIP.
      !strcontains(module.monitoring.alloy_configs.mon01, "loki.source.syslog") &&
      strcontains(module.monitoring.alloy_configs.graf01, "url = \"http://10.55.18.101:3100/loki/api/v1/push\"") &&
      !strcontains(module.monitoring.units.mon01.alloy, "stability.level") &&
      strcontains(module.monitoring.units.graf02.alloy, "--server.http.listen-addr=10.55.11.33:12345") &&
      contains(module.monitoring.backend_services, "alloy")
    )
    error_message = "Alloy: syslog (TCP/UDP 514, raw UDP 1514) on the logging VMs into the local Loki; journal-only on mon01/graf to the telemetry VIP."
  }

  assert {
    condition = (
      # Syslog goes through the VyOS dedup stage, the journal straight to Loki.
      strcontains(module.monitoring.alloy_configs.loki01, "forward_to    = [loki.process.syslog.receiver]") &&
      strcontains(module.monitoring.alloy_configs.loki01, "selector            = \"{host=~\\\"LEAF-[0-9]+|fw-wan|dhcp0[0-9]\\\", app!=\\\"kernel\\\"} |~ \\\"^ [^ ]\\\"\"") &&
      strcontains(module.monitoring.alloy_configs.loki01, "action              = \"drop\"") &&
      !strcontains(module.monitoring.alloy_configs.mon01, "loki.process")
    )
    error_message = "Alloy: the VyOS imuxsock copies (one leading space, not kernel) are dropped before Loki on the logging VMs."
  }

  assert {
    condition = alltrue([for name in ["loki01", "loki02", "loki03"] : (
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
      strcontains(module.monitoring.prometheus_config, "10.54.18.34:3100") &&
      strcontains(module.monitoring.prometheus_config, "10.54.18.36:8405") &&
      strcontains(module.monitoring.prometheus_config, "10.55.16.30:12345") &&
      strcontains(module.monitoring.prometheus_config, "10.55.18.35:9100") &&
      strcontains(module.monitoring.units.loki02["node-exporter"], "--collector.netdev.address-info") &&
      length([for g in yamldecode(module.monitoring.prometheus_rules).groups : g if g.name == "logging"]) == 1 &&
      length([for r in one([for g in yamldecode(module.monitoring.prometheus_rules).groups : g.rules if g.name == "logging"]) : r if r.alert == "LoggingVIPNotHeldOnce"]) == 3 &&
      strcontains(module.monitoring.prometheus_rules, "loki_ingester_chunks_flush_failures_total") &&
      strcontains(module.monitoring.prometheus_rules, "loki_source_syslog_entries_total")
    )
    error_message = "Prometheus scrapes Loki, haproxy, Alloy and node_exporter on the logging VMs (Loki and haproxy over the backend VLAN, Alloy and node_exporter over lylat-telemetry), with logging alerts (one VIP rule per VIP: backend, monitoring, telemetry; none on mgmt)."
  }

  assert {
    condition = (
      strcontains(module.monitoring.datasources_config, "\"uid\": \"loki\"") &&
      strcontains(module.monitoring.datasources_config, "\"url\": \"http://10.54.18.101:3100\"") &&
      # $$ escapes Grafana's environment expansion of provisioning files.
      # (?i): Loki has the VyOS hosts in upper case, Prometheus in lower case.
      one([for d in yamldecode(module.monitoring.datasources_config).datasources : d.jsonData.derivedFields[0].url if d.uid == "loki"]) == "up{host=~\"(?i)$$${__value.raw}\"}"
    )
    error_message = "Grafana gets a Loki datasource (uid loki) on the backend VIP, linking the host label to Prometheus (case-insensitively)."
  }

  assert {
    condition = alltrue([for name in ["loki01", "loki02", "loki03"] : (
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
            { bridge = "vmbr4000", vlan_id = 1401, ipv4_address = "10.54.16.30/16" },
            { bridge = "vmbr100", ipv4_address = "10.5.11.30/16" },
          ]
        }
      },
      { for name, i in { loki01 = 34, loki02 = 35, loki03 = 36 } : name => {
        owner                   = "services-vms"
        role                    = "logging"
        node                    = "zoness"
        vm_id                   = 1100 + i
        management_address      = "10.20.11.${i}/16"
        network_devices = [
          { bridge = "vmbr4000", vlan_id = 1401, ipv4_address = "10.54.18.${i}/16" },
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
    condition = alltrue([for name, i in { graf01 = 32, graf02 = 33 } : (
      strcontains(module.monitoring.units[name].grafana, "GF_UNIFIED_ALERTING_HA_ADVERTISE_ADDRESS=10.50.11.${i}:9094") &&
      strcontains(module.monitoring.units[name].grafana, "PublishPort=10.50.11.${i}:9094:9094/udp") &&
      !strcontains(module.monitoring.units[name].grafana, "10.52.11.${i}:9094")
    )])
    error_message = "Grafana alerting HA gossips over 10.50.11.32/.33:9094."
  }

  assert {
    # VIP on the UI NIC (eth1, VLAN 1201 lylat-app), adverts unicast on the HA NIC (eth2), router id 100.
    condition = (
      strcontains(nonsensitive(module.monitoring.grafana_keepalived_configs.graf01), "10.52.11.100/16 dev eth1") &&
      strcontains(nonsensitive(module.monitoring.grafana_keepalived_configs.graf01), "interface eth2") &&
      strcontains(nonsensitive(module.monitoring.grafana_keepalived_configs.graf01), "unicast_src_ip fd69:5011::32") &&
      strcontains(nonsensitive(module.monitoring.grafana_keepalived_configs.graf01), "    fd69:5011::33\n") &&
      strcontains(nonsensitive(module.monitoring.grafana_keepalived_configs.graf01), "priority 150") &&
      strcontains(nonsensitive(module.monitoring.grafana_keepalived_configs.graf02), "priority 100") &&
      strcontains(nonsensitive(module.monitoring.grafana_keepalived_configs.graf02), "virtual_router_id 100")
    )
    error_message = "keepalived on graf01/02: VIP 10.52.11.100 on eth1, unicast adverts over eth2, vrid 100, name-ordered priority."
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

# Backend HA (backends.tf): mon01 (primary, Postgres) + mon02, Alertmanager cluster and
# keepalived over the ha_monitor VLAN 215, VIPs 10.5.11.102 / 10.54.16.102.
run "backend_ha" {
  command = plan

  assert {
    # Same scrapes on both, only __replica__ differs; alerts lose it so the AM cluster dedups.
    condition = alltrue([for name in ["mon01", "mon02"] : (
      yamldecode(module.monitoring.prometheus_configs[name]).global.external_labels == { site = "lylat", ha_cluster = "lylat", __replica__ = name } &&
      yamldecode(module.monitoring.prometheus_configs[name]).alerting.alert_relabel_configs == [{ action = "labeldrop", regex = "__replica__" }] &&
      yamldecode(module.monitoring.prometheus_configs[name]).alerting.alertmanagers[0].static_configs[0].targets == ["10.54.16.30:9093", "10.54.16.31:9093"] &&
      yamldecode(module.monitoring.prometheus_configs[name]).scrape_configs == yamldecode(module.monitoring.prometheus_configs.mon01).scrape_configs
    )])
    error_message = "Both replicas scrape the same targets with __replica__ = their name, and send to both Alertmanagers."
  }

  assert {
    condition = (
      strcontains(module.monitoring.prometheus_config, "10.54.16.31:9090") && # every replica's Prometheus and Alertmanager
      strcontains(module.monitoring.prometheus_config, "10.54.16.31:9093") &&
      strcontains(module.monitoring.prometheus_config, "10.55.16.31:9100") &&
      !strcontains(module.monitoring.prometheus_config, "localhost:9090") &&
      strcontains(module.monitoring.prometheus_rules, "AlertmanagerClusterDegraded") &&
      strcontains(module.monitoring.prometheus_rules, "address=\\\"10.5.11.102\\\"") &&
      strcontains(module.monitoring.prometheus_rules, "address=\\\"10.54.16.102\\\"")
    )
    error_message = "Every replica scrapes every Prometheus/Alertmanager by address; HA alerts cover the cluster and both VIPs."
  }

  assert {
    # Postgres only on the primary; mon02 runs everything else.
    condition = (
      !contains(keys(module.monitoring.units.mon02), "postgres") &&
      !strcontains(nonsensitive(module.monitoring.backend_deployments.mon02), "/var/lib/monitoring/postgres") &&
      !strcontains(nonsensitive(module.monitoring.backend_deployments.mon02), "pg_isready") &&
      module.monitoring.backend_services_by_host.mon02 == ["monitoring-network", "telegraf", "pvestatd", "snmp-exporter", "blackbox-exporter", "alertmanager", "prometheus", "node-exporter", "alloy", "keepalived"] &&
      strcontains(module.monitoring.units.graf01.grafana, "GF_DATABASE_HOST=10.54.16.30:5432")
    )
    error_message = "Postgres stays on mon01 (Grafana's database); mon02 gets the rest, keepalived last."
  }

  assert {
    # Alertmanager gossip on the HA VLAN, published only there.
    condition = alltrue([for name, i in { mon01 = { me = 30, peer = 31 }, mon02 = { me = 31, peer = 30 } } : (
      strcontains(module.monitoring.units[name].alertmanager, "--cluster.advertise-address=10.50.16.${i.me}:9094") &&
      strcontains(module.monitoring.units[name].alertmanager, "--cluster.peer=10.50.16.${i.peer}:9094") &&
      strcontains(module.monitoring.units[name].alertmanager, "PublishPort=10.50.16.${i.me}:9094:9094/udp") &&
      strcontains(module.monitoring.units[name].alertmanager, "PublishPort=10.54.16.102:9093:9093\n") &&
      strcontains(module.monitoring.units[name].telegraf, "PublishPort=10.5.11.102:57500:57500\n") &&
      strcontains(module.monitoring.units[name]["node-exporter"], "--collector.netdev.address-info")
    )])
    error_message = "Alertmanager gossips over 10.50.16.30/.31:9094; the WLC Telegraf and Alertmanager also publish on the VIPs."
  }

  assert {
    # VIPs on eth2 (vmbr100) and eth1 (VLAN 1401 lylat-obs), adverts unicast on eth3 (VLAN 215), router id 102.
    condition = (
      strcontains(nonsensitive(module.monitoring.backend_keepalived_configs.mon01), "10.5.11.102/16 dev eth2") &&
      strcontains(nonsensitive(module.monitoring.backend_keepalived_configs.mon01), "10.54.16.102/16 dev eth1") &&
      strcontains(nonsensitive(module.monitoring.backend_keepalived_configs.mon01), "interface eth3") &&
      strcontains(nonsensitive(module.monitoring.backend_keepalived_configs.mon01), "unicast_src_ip fd69:5016::30") &&
      strcontains(nonsensitive(module.monitoring.backend_keepalived_configs.mon01), "    fd69:5016::31\n") &&
      strcontains(nonsensitive(module.monitoring.backend_keepalived_configs.mon01), "priority 150") &&
      strcontains(nonsensitive(module.monitoring.backend_keepalived_configs.mon02), "priority 100") &&
      strcontains(nonsensitive(module.monitoring.backend_keepalived_configs.mon02), "virtual_router_id 102") &&
      strcontains(nonsensitive(module.monitoring.backend_deployments.mon02), base64encode(module.monitoring.backend_keepalived_configs.mon02)) &&
      strcontains(nonsensitive(module.monitoring.backend_deployments.mon02), "sysctl -q -p /etc/sysctl.d/90-monitoring-vip.conf") &&
      output.monitoring_vips == { monitoring = "10.5.11.102", backend = "10.54.16.102" }
    )
    error_message = "keepalived on mon01/02: VIPs on eth2/eth1, unicast adverts over eth3, vrid 102, mon01 first; nonlocal bind applied."
  }

  assert {
    # Grafana: Alertmanager on the backend VIP, per-replica Prometheus datasources.
    condition = (
      one([for d in yamldecode(module.monitoring.datasources_config).datasources : d.url if d.uid == "alertmanager"]) == "http://10.54.16.102:9093" &&
      one([for d in yamldecode(module.monitoring.datasources_config).datasources : d.url if d.uid == "prometheus-mon01"]) == "http://10.54.16.30:9090" &&
      one([for d in yamldecode(module.monitoring.datasources_config).datasources : d.url if d.uid == "prometheus-mon02"]) == "http://10.54.16.31:9090"
    )
    error_message = "Grafana reaches Alertmanager on the backend VIP, and each Prometheus replica directly."
  }
}

# The telemetry for Prometheus: a renamed clone (wlc_*, starlark) served on :9275 on all local addresses,
# scraped through the backend VIP by both replicas (job wlc). IOS XE keeps one receiver per subscription
# active, so the WLCs send to the monitoring VIP and only the holder's Telegraf receives.
run "wlc_prometheus" {
  command = plan

  assert {
    condition = (
      alltrue([for name in ["mon01", "mon02"] : (
        strcontains(module.monitoring.units[name].telegraf, "PublishPort=9275:9275\n") &&
        strcontains(module.monitoring.wlc_telegraf_configs[name], "name_prefix = \"wlc_\"") &&
        strcontains(module.monitoring.wlc_telegraf_configs[name], "script = \"/etc/telegraf/wlc.star\"") &&
        strcontains(module.monitoring.wlc_telegraf_configs[name], "listen = \":9275\"") &&
        strcontains(nonsensitive(module.monitoring.backend_deployments[name]), "put '/etc/monitoring/telegraf/wlc.star'")
      )]) &&
      one([for j in yamldecode(module.monitoring.prometheus_config).scrape_configs : j if j.job_name == "wlc"]).static_configs[0].targets == ["10.54.16.102:9275"] &&
      strcontains(module.monitoring.prometheus_rules, "WlcTelemetryNotInPrometheus") &&
      contains(flatten([for g in yamldecode(module.monitoring.prometheus_rules).groups : g.rules[*].expr if g.name == "wlc-telemetry"]), "sum(rate(internal_gather_metrics_gathered{job=\"telegraf\", input=\"cisco_telemetry_mdt\"}[10m])) == 0")
    )
    error_message = "The WLC Telegraf serves wlc_* clones on :9275 (all addresses), scraped via the backend VIP; WlcTelemetryStopped sums over both Telegrafs."
  }
}

run "backend_vrrp_disabled" {
  command = plan
  variables { backend_vrrp = null }

  assert {
    condition = (
      nonsensitive(module.monitoring.backend_keepalived_configs.mon01) == null &&
      output.monitoring_vips == null &&
      !contains(module.monitoring.backend_services, "keepalived") &&
      !strcontains(module.monitoring.units.mon01.telegraf, "10.5.11.102") &&
      one([for d in yamldecode(module.monitoring.datasources_config).datasources : d.url if d.uid == "alertmanager"]) == "http://10.54.16.30:9093"
    )
    error_message = "backend_vrrp = null: no keepalived or VIP publishing; Grafana uses the primary."
  }
}

run "backend_ha_nic_required" {
  command = plan

  # Two backends with backend_vrrp on, but mon02 has no ha_monitor (215) NIC.
  variables {
    vms = { for name, i in { mon01 = 30, mon02 = 31 } : name => {
      owner              = "services-vms"
      role               = "monitoring"
      node               = "zoness"
      vm_id              = 1100 + i
      management_address = "10.20.11.${i}/16"
      network_devices = concat([
        { bridge = "vmbr4000", vlan_id = 1401, ipv4_address = "10.54.16.${i}/16", ipv4_gateway = "10.54.0.1" },
        { bridge = "vmbr100", ipv4_address = "10.5.11.${i}/16" },
      ], name == "mon01" ? [{ bridge = "vmbr4000", vlan_id = 1016, ipv4_address = "10.50.16.${i}/24" }] : [])
    } }
  }

  expect_failures = [terraform_data.backend]
}

# A single backend (mon02 left out of the inventory): mon01 alone, no cluster, no VIPs; Grafana
# uses mon01.
run "backend_single" {
  command = plan
  variables { vms = { for name, vm in var.vms : name => vm if name != "mon02" } }

  assert {
    condition = (
      keys(terraform_data.backend) == ["mon01"] &&
      nonsensitive(module.monitoring.backend_keepalived_configs.mon01) == null &&
      output.monitoring_vips == null &&
      !contains(module.monitoring.backend_services, "keepalived") &&
      strcontains(module.monitoring.units.mon01.alertmanager, "--cluster.listen-address=\n") &&
      !strcontains(module.monitoring.units.mon01.alertmanager, "--cluster.peer") &&
      !strcontains(module.monitoring.units.mon01.telegraf, "10.5.11.102") &&
      yamldecode(module.monitoring.prometheus_config).global.external_labels.__replica__ == "mon01" &&
      yamldecode(module.monitoring.prometheus_config).alerting.alertmanagers[0].static_configs[0].targets == ["10.54.16.30:9093"] &&
      !strcontains(module.monitoring.prometheus_config, "10.54.16.31") &&
      !strcontains(module.monitoring.prometheus_rules, "AlertmanagerClusterDegraded") &&
      one([for d in yamldecode(module.monitoring.datasources_config).datasources : d.url if d.uid == "alertmanager"]) == "http://10.54.16.30:9093" &&
      !contains([for d in yamldecode(module.monitoring.datasources_config).datasources : d.uid], "prometheus-mon02") &&
      output.wlc_telemetry_receiver.address == "10.5.11.30" # no VIP: the primary's own address
    )
    error_message = "Without mon02, mon01 runs alone: no Alertmanager peers, no keepalived/VIPs, Grafana on mon01."
  }
}

run "service_vm_alloy" {
  command = plan

  assert {
    # services-config's Alloy (alloy.tf) on the telemetry address (lylat-telemetry), next to this root's own Alloys.
    condition = (
      alltrue([for a in ["10.55.53.51", "10.55.53.52", "10.55.13.43", "10.55.13.44", "10.55.12.45", "10.55.12.46", "10.55.15.47", "10.55.15.48", "10.55.15.49", "10.55.10.50", "10.55.10.51"] :
      strcontains(module.monitoring.prometheus_config, "${a}:12345")]) &&
      strcontains(module.monitoring.prometheus_config, "10.55.16.30:12345") &&
      # triage01/02 in the node job with their role (overview hosts and VIP tables).
      strcontains(module.monitoring.prometheus_config, "10.55.13.43:9100") &&
      strcontains(module.monitoring.prometheus_config, "\"role\": \"ticketing\"")
    )
    error_message = "Scrape Alloy on every services-config VM's telemetry address :12345 and node_exporter on triage01/02 (role ticketing)."
  }

  assert {
    # Every services-config Alloy VM has a telemetry NIC (since 2026-11-14) and pushes to the telemetry VIP, so
    # logging-guard needs no mgmt exceptions: only lylat-app (Grafana), lylat-obs and lylat-telemetry reach port 3100.
    condition = (
      strcontains(module.monitoring.logging_guard_config, "tcp dport 3100 ip saddr { 10.52.0.0/16, 10.54.0.0/16, 10.55.0.0/16 } accept")
    )
    error_message = "No mgmt senders left: logging-guard lets only 10.52.0.0/16, 10.54.0.0/16 and 10.55.0.0/16 reach Loki's port 3100."
  }
}
