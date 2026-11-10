# Mimir on the role = "metrics" VMs (mim01-03): metrics.tf here and in the module.

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

override_resource {
  target = random_password.mimir_vrrp
  values = { result = "mimirvrp" }
}

mock_provider "influxdb" {
  mock_data "influxdb_organization" {
    defaults = { id = "0123456789abcdef" }
  }
  mock_resource "influxdb_bucket" {
    defaults = { id = "fedcba9876543210" }
  }
}

# The replica backend's InfluxDB (influxdb-replica.tf).
mock_provider "influxdb" {
  alias = "replica"
  mock_data "influxdb_organization" {
    defaults = { id = "1123456789abcdef" }
  }
  mock_resource "influxdb_bucket" {
    defaults = { id = "1edcba9876543210" }
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
  postgres_settings    = {} # the default; postgres.auto.tfvars (the live cutover) would leak in
  loki_s3              = { bucket = "loki", access_key = "MOCKACCESSKEY", secret_key = "mocksecretkeymocksecretkey" }
  mimir_s3             = { bucket = "mimir", access_key = "MOCKMIMIRKEY", secret_key = "mockmimirsecretmockmimirsecret" }
  postgres_s3          = { bucket = "postgres", access_key = "MOCKPGKEY", secret_key = "mockpgsecretmockpgsecret" } # postgres.tftest.hcl
}

run "mimir" {
  command = plan

  assert {
    condition = (
      length(terraform_data.metrics) == 3 &&
      output.mimir_url == "http://10.13.11.103:8080" &&
      output.mimir_urls == { mim01 = "http://10.13.11.37:8080", mim02 = "http://10.13.11.38:8080", mim03 = "http://10.13.11.39:8080" }
    )
    error_message = "Deploy Mimir on mim01-03, reached through the backend VIP 10.13.11.103:8080."
  }

  assert {
    # Classic architecture, ring and gossip on the Mimir HA VLAN (216), S3 through the local haproxy.
    condition = alltrue([for name, i in { mim01 = 37, mim02 = 38, mim03 = 39 } : (
      yamldecode(module.monitoring.mimir_configs[name]).target == "all" &&
      yamldecode(module.monitoring.mimir_configs[name]).multitenancy_enabled == false &&
      yamldecode(module.monitoring.mimir_configs[name]).ingest_storage.enabled == false &&
      yamldecode(module.monitoring.mimir_configs[name]).ingester.ring.instance_addr == "10.21.14.${i}" &&
      yamldecode(module.monitoring.mimir_configs[name]).ingester.ring.replication_factor == 3 &&
      yamldecode(module.monitoring.mimir_configs[name]).store_gateway.sharding_ring.instance_addr == "10.21.14.${i}" &&
      yamldecode(module.monitoring.mimir_configs[name]).memberlist.advertise_addr == "10.21.14.${i}" &&
      yamldecode(module.monitoring.mimir_configs[name]).memberlist.cluster_label == "lylat-mimir" &&
      yamldecode(module.monitoring.mimir_configs[name]).memberlist.join_members == ["10.21.14.37:7946", "10.21.14.38:7946", "10.21.14.39:7946"] &&
      yamldecode(module.monitoring.mimir_configs[name]).blocks_storage.s3.endpoint == "127.0.0.1:7480" &&
      yamldecode(module.monitoring.mimir_configs[name]).blocks_storage.s3.bucket_name == "mimir" &&
      !strcontains(module.monitoring.mimir_configs[name], "MOCKMIMIRKEY") &&
      !strcontains(module.monitoring.mimir_configs[name], "mockmimirsecret")
    )])
    error_message = "Mimir: monolithic, classic architecture, RF 3, ring on 10.21.14.x, S3 via 127.0.0.1:7480, no keys in mimir.yaml."
  }

  assert {
    # HA tracker on memberlist; the HA cluster label and site are dropped after dedup; limits and retention.
    condition = (
      yamldecode(module.monitoring.mimir_configs.mim01).distributor.ha_tracker.enable_ha_tracker &&
      yamldecode(module.monitoring.mimir_configs.mim01).distributor.ha_tracker.kvstore.store == "memberlist" &&
      yamldecode(module.monitoring.mimir_configs.mim01).limits.accept_ha_samples &&
      yamldecode(module.monitoring.mimir_configs.mim01).limits.ha_cluster_label == "ha_cluster" &&
      yamldecode(module.monitoring.mimir_configs.mim01).limits.ha_replica_label == "__replica__" &&
      yamldecode(module.monitoring.mimir_configs.mim01).limits.drop_labels == ["ha_cluster", "site"] &&
      yamldecode(module.monitoring.mimir_configs.mim01).limits.max_global_series_per_user == 300000 &&
      yamldecode(module.monitoring.mimir_configs.mim01).limits.compactor_blocks_retention_period == "396d" &&
      yamldecode(module.monitoring.mimir_configs.mim01).limits.compactor_block_upload_enabled
    )
    error_message = "Mimir: HA tracker (memberlist, ha_cluster/__replica__), drop_labels, 300k series, 396d retention, block upload on."
  }

  assert {
    # Prometheus pushes to the VIP and scrapes every Mimir and its haproxy over the backend VLAN.
    condition = (
      one(yamldecode(module.monitoring.prometheus_config).remote_write).url == "http://10.13.11.103:8080/api/v1/push" &&
      strcontains(module.monitoring.prometheus_config, "\"job_name\": \"mimir\"") &&
      strcontains(module.monitoring.prometheus_config, "10.13.11.38:8080") &&
      strcontains(module.monitoring.prometheus_config, "\"job_name\": \"haproxy-mimir\"") &&
      strcontains(module.monitoring.prometheus_config, "10.13.11.39:8405") &&
      strcontains(module.monitoring.prometheus_config, "10.13.11.37:9100") &&  # node job, role metrics
      strcontains(module.monitoring.prometheus_config, "10.13.11.37:12345") && # Alloy
      length([for g in yamldecode(module.monitoring.prometheus_rules).groups : g if g.name == "metrics"]) == 1 &&
      strcontains(module.monitoring.prometheus_rules, "MimirVIPNotHeldOnce") &&
      strcontains(module.monitoring.prometheus_rules, "PrometheusRemoteWriteBehind")
    )
    error_message = "Prometheus remote_writes to the Mimir VIP, scrapes Mimir/haproxy/node/Alloy on mim01-03 and has the metrics alerts."
  }

  assert {
    # Grafana's default datasource keeps uid "prometheus" but queries Mimir.
    condition = (
      one([for d in yamldecode(module.monitoring.datasources_config).datasources : d.url if d.uid == "prometheus"]) == "http://10.13.11.103:8080/prometheus" &&
      one([for d in yamldecode(module.monitoring.datasources_config).datasources : d.jsonData.prometheusType if d.uid == "prometheus"]) == "Mimir"
    )
    error_message = "The \"prometheus\" datasource points at Mimir (/prometheus on the VIP)."
  }

  assert {
    # VIP on the backend NIC (eth2), adverts unicast on the HA NIC (eth4), router id 103, Mimir /ready check.
    condition = (
      strcontains(nonsensitive(module.monitoring.mimir_keepalived_configs.mim01), "10.13.11.103/16 dev eth2") &&
      strcontains(nonsensitive(module.monitoring.mimir_keepalived_configs.mim01), "interface eth4") &&
      strcontains(nonsensitive(module.monitoring.mimir_keepalived_configs.mim01), "unicast_src_ip 10.21.14.37") &&
      strcontains(nonsensitive(module.monitoring.mimir_keepalived_configs.mim01), "    10.21.14.39\n") &&
      strcontains(nonsensitive(module.monitoring.mimir_keepalived_configs.mim01), "virtual_router_id 103") &&
      strcontains(nonsensitive(module.monitoring.mimir_keepalived_configs.mim01), "auth_pass mimirvrp") &&
      strcontains(nonsensitive(module.monitoring.mimir_keepalived_configs.mim01), "http://127.0.0.1:8080/ready") &&
      strcontains(nonsensitive(module.monitoring.mimir_keepalived_configs.mim01), "priority 150") &&
      strcontains(nonsensitive(module.monitoring.mimir_keepalived_configs.mim03), "priority 50")
    )
    error_message = "keepalived on mim01-03: VIP 10.13.11.103 on eth2, unicast adverts over eth4, vrid 103, Mimir /ready check."
  }

  assert {
    condition = alltrue([for name in ["mim01", "mim02", "mim03"] : (
      strcontains(module.monitoring.mimir_haproxy_configs[name], "S3 for Mimir on ${name}") &&
      strcontains(module.monitoring.mimir_haproxy_configs[name], "server rgw1 10.27.0.12:7480") &&
      strcontains(module.monitoring.units[name].mimir, "Image=docker.io/grafana/mimir:3.2.4") &&
      strcontains(module.monitoring.units[name].mimir, "EnvironmentFile=/etc/metrics/mimir.env") &&
      strcontains(module.monitoring.units[name]["node-exporter"], "--collector.netdev.address-info") &&
      strcontains(module.monitoring.alloy_configs[name], "url = \"${output.loki_url}/loki/api/v1/push\"") && # the Loki VIP
      strcontains(nonsensitive(module.monitoring.metrics_deployments[name]), "-config.expand-env=true -modules") &&
      strcontains(nonsensitive(module.monitoring.metrics_deployments[name]), "nft -c -f") &&
      strcontains(nonsensitive(module.monitoring.metrics_deployments[name]), "for pkg in keepalived; do") &&
      strcontains(nonsensitive(module.monitoring.metrics_deployments[name]), "put '/etc/metrics/mimir.env' '0600' 'root' 'mimir' ''") &&
      strcontains(nonsensitive(module.monitoring.metrics_deployments[name]), base64encode("MIMIR_S3_ACCESS_KEY=MOCKMIMIRKEY\nMIMIR_S3_SECRET_KEY=mockmimirsecretmockmimirsecret\n"))
    )])
    error_message = "Each Mimir deploy.sh validates Mimir/Alloy/haproxy/nftables, installs keepalived, and keeps the S3 keys in a 0600 env file."
  }

  assert {
    # The Loki VMs' haproxy.cfg renders exactly as before the template gained ${client}.
    condition     = strcontains(module.monitoring.haproxy_configs.loki01, "# S3 for Loki on loki01: 127.0.0.1:7480") && strcontains(module.monitoring.haproxy_configs.loki01, "without Loki noticing")
    error_message = "haproxy.cfg on the Loki VMs is unchanged."
  }
}

run "mimir_without_s3_keys" {
  command = plan

  variables {
    mimir_s3 = null
  }

  # The check warns; nothing Mimir-related is deployed or wired up.
  expect_failures = [check.mimir_s3]

  assert {
    condition = (
      length(terraform_data.metrics) == 0 &&
      output.mimir_url == null &&
      !can(yamldecode(module.monitoring.prometheus_config).remote_write[0]) &&
      !strcontains(module.monitoring.prometheus_config, "10.13.11.37") &&
      !strcontains(module.monitoring.prometheus_rules, "Mimir") &&
      !contains(keys(module.monitoring.alloy_configs), "mim01") &&
      !contains(keys(module.monitoring.units), "mim01") &&
      one([for d in yamldecode(module.monitoring.datasources_config).datasources : d.url if d.uid == "prometheus"]) != "http://10.13.11.103:8080/prometheus"
    )
    error_message = "Without mimir_s3: no Mimir deployment, no remote_write, no Mimir scrape targets, Grafana stays on Prometheus."
  }
}

run "mimir_ha_nic_required" {
  command = plan

  # The metrics VMs without their HA VLAN (216) NIC.
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
      { for name, i in { mim01 = 37, mim02 = 38, mim03 = 39 } : name => {
        owner                  = "services-vms"
        role                   = "metrics"
        node                   = "fichina"
        vm_id                  = 1100 + i
        management_address     = "10.20.11.${i}/16"
        network_devices = [
          { bridge = "vmbr4000", vlan_id = 13, ipv4_address = "10.13.11.${i}/16" },
          { bridge = "vmbr27", ipv4_address = "10.27.11.${i}/16" },
        ]
      } },
    )
  }

  expect_failures = [terraform_data.metrics]
}
