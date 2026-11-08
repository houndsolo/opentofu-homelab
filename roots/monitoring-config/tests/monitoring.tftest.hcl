mock_provider "random" {
  mock_resource "random_password" {
    defaults = { result = "mockmockmockmockmockmockmockmock" }
  }
}

variables {
  ssh_private_key_path = "/dev/null"
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
      strcontains(module.monitoring.units.mon01.prometheus, "ExecReload=/usr/bin/podman kill --signal HUP prometheus")
    )
    error_message = "Validate before install, bind Postgres to the backend VLAN only, and peer Grafana over it."
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
