# The Patroni cluster on the role = "postgres" VMs (pg01-03): postgres.tf here and in the module.

mock_provider "random" {
  mock_resource "random_password" {
    defaults = { result = "mockmockmockmockmockmockmockmock" }
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
  postgres_settings    = {} # the defaults
  loki_s3              = { bucket = "loki", access_key = "MOCKACCESSKEY", secret_key = "mocksecretkeymocksecretkey" }
  mimir_s3             = { bucket = "mimir", access_key = "MOCKMIMIRKEY", secret_key = "mockmimirsecretmockmimirsecret" }
  postgres_s3          = { bucket = "postgres", access_key = "MOCKPGKEY", secret_key = "mockpgsecretmockpgsecret" }
}

run "postgres_cluster" {
  command = plan

  assert {
    condition = (
      length(terraform_data.postgres) == 3 &&
      output.postgres_vip == "10.56.14.104:5432" &&
      output.patroni_urls == { pg01 = "http://10.56.14.40:8008", pg02 = "http://10.56.14.41:8008", pg03 = "http://10.56.14.42:8008" }
    )
    error_message = "Deploy Patroni on pg01-03 (.40-.42), the leader reached through the VIP 10.56.14.104:5432."
  }

  assert {
    # Replication, REST and etcd on the Postgres HA VLAN (1014); everything listens everywhere for the VIP.
    condition = alltrue([for name, i in { pg01 = 40, pg02 = 41, pg03 = 42 } : (
      yamldecode(module.monitoring.patroni_configs[name]).scope == "lylat-pg18" &&
      yamldecode(module.monitoring.patroni_configs[name]).postgresql.data_dir == "/var/lib/postgresql/patroni/18" &&
      yamldecode(module.monitoring.patroni_configs[name]).postgresql.bin_dir == "/usr/lib/postgresql/18/bin" &&
      yamldecode(module.monitoring.patroni_configs[name]).name == name &&
      yamldecode(module.monitoring.patroni_configs[name]).restapi.connect_address == "10.50.14.${i}:8008" &&
      yamldecode(module.monitoring.patroni_configs[name]).postgresql.connect_address == "10.50.14.${i}:5432" &&
      yamldecode(module.monitoring.patroni_configs[name]).postgresql.listen == "0.0.0.0:5432" &&
      yamldecode(module.monitoring.patroni_configs[name]).etcd3.hosts == ["10.50.14.40:2379", "10.50.14.41:2379", "10.50.14.42:2379"] &&
      yamldecode(module.monitoring.patroni_configs[name]).bootstrap.dcs.failsafe_mode == true &&
      yamldecode(module.monitoring.patroni_configs[name]).postgresql.parameters.archive_command == "pgbackrest --stanza=lylat-pg18 archive-push %p" &&
      yamldecode(module.monitoring.patroni_configs[name]).postgresql.parameters.password_encryption == "scram-sha-256" &&
      yamldecode(module.monitoring.etcd_configs[name]).listen-peer-urls == "http://10.50.14.${i}:2380" &&
      yamldecode(module.monitoring.etcd_configs[name]).listen-metrics-urls == "http://10.56.14.${i}:2381" &&
      yamldecode(module.monitoring.etcd_configs[name]).initial-cluster == "pg01=http://10.50.14.40:2380,pg02=http://10.50.14.41:2380,pg03=http://10.50.14.42:2380" &&
      yamldecode(module.monitoring.etcd_configs[name]).initial-cluster-state == "new" &&
      # etcd keeps cluster_name across Postgres majors: a new data dir/token would be a new etcd cluster.
      yamldecode(module.monitoring.etcd_configs[name]).data-dir == "/var/lib/etcd/lylat-pg" &&
      yamldecode(module.monitoring.etcd_configs[name]).initial-cluster-token == "lylat-pg"
    )])
    error_message = "Patroni and etcd use the HA VLAN addresses 10.50.14.40-42; etcd metrics on the backend VLAN."
  }

  assert {
    # Slow Ceph RBD fsync (DT-017): heartbeat 300 ms, election 3000 ms on every member (defaults 100/1000).
    condition = alltrue([for name in ["pg01", "pg02", "pg03"] : (
      yamldecode(module.monitoring.etcd_configs[name]).heartbeat-interval == 300 &&
      yamldecode(module.monitoring.etcd_configs[name]).election-timeout == 3000
    )])
    error_message = "etcd runs with heartbeat-interval 300 ms and election-timeout 3000 ms (slow-disk tuning, DT-017)."
  }

  assert {
    # No passwords in the Patroni config; pg_hba: Grafana (TLS) from graf01/02's backend addresses,
    # replication and the superuser only from the members.
    condition = (
      !strcontains(module.monitoring.patroni_configs.pg01, "mockmock") &&
      contains(yamldecode(module.monitoring.patroni_configs.pg01).postgresql.pg_hba, "hostssl grafana grafana ${local.backend_address.graf01}/32 scram-sha-256") &&
      contains(yamldecode(module.monitoring.patroni_configs.pg01).postgresql.pg_hba, "hostssl grafana grafana ${local.backend_address.graf02}/32 scram-sha-256") &&
      contains(yamldecode(module.monitoring.patroni_configs.pg01).postgresql.pg_hba, "host replication replicator 10.50.14.42/32 scram-sha-256") &&
      length([for l in yamldecode(module.monitoring.patroni_configs.pg01).postgresql.pg_hba : l if strcontains(l, "0.0.0.0/0")]) == 0 &&
      contains(yamldecode(module.monitoring.patroni_configs.pg01).postgresql.pg_hba, "host replication replicator 127.0.0.1/32 scram-sha-256") &&
      length([for l in yamldecode(module.monitoring.patroni_configs.pg01).postgresql.pg_hba : l if startswith(l, "host replication")]) == 4
    )
    error_message = "pg_hba allows Grafana from graf01/02 (hostssl), replication/superuser only from pg01-03, and Patroni's local replication check on loopback."
  }

  assert {
    # The guard: 5432 from Grafana + members, etcd only from members, REST/etcd metrics from the Prometheus backends.
    condition = (
      strcontains(module.monitoring.postgres_guard, "tcp dport { 2379, 2380 } ip saddr { 10.50.14.40, 10.50.14.41, 10.50.14.42 } accept") &&
      strcontains(module.monitoring.postgres_guard, "tcp dport 2381 ip saddr { ${local.backend_address.mon01}, ${local.backend_address.mon02} } accept") &&
      strcontains(module.monitoring.postgres_guard, "tcp dport 5432 ip saddr { ${local.backend_address.graf01}, ${local.backend_address.graf02}, 10.50.14.40") &&
      strcontains(module.monitoring.postgres_guard, "tcp dport { 5432, 8008, 2379, 2380, 2381 } drop")
    )
    error_message = "postgres-guard limits 5432/8008/2379-2381 to Grafana, the members and Prometheus."
  }

  assert {
    # VIP on eth1 (VLAN 1601, lylat-data), adverts unicast on eth3 (VLAN 1014), router id 104, check = Patroni /primary.
    condition = alltrue([for name, i in { pg01 = 40, pg02 = 41, pg03 = 42 } : (
      strcontains(module.monitoring.postgres_keepalived_configs[name], "10.56.14.104/16 dev eth1") &&
      strcontains(module.monitoring.postgres_keepalived_configs[name], "interface eth3") &&
      strcontains(module.monitoring.postgres_keepalived_configs[name], "unicast_src_ip fd69:5014::${i}") &&
      strcontains(module.monitoring.postgres_keepalived_configs[name], "virtual_router_id 104") &&
      strcontains(module.monitoring.postgres_keepalived_configs[name], "http://127.0.0.1:8008/primary") &&
      strcontains(module.monitoring.postgres_keepalived_configs[name], "fd69:5014::104/64 dev eth3") &&
      strcontains(module.monitoring.postgres_keepalived_configs[name], "vrrp_version 3")
    )])
    error_message = "keepalived holds 10.56.14.104 on the Patroni leader only (router id 104, adverts over VLAN 1014)."
  }

  assert {
    # pgBackRest to the postgres bucket through the local TLS haproxy; keys only in s3.env.
    condition = (
      strcontains(module.monitoring.pgbackrest_conf, "repo1-s3-bucket=postgres") &&
      strcontains(module.monitoring.pgbackrest_conf, "repo1-storage-port=7443") &&
      strcontains(module.monitoring.pgbackrest_conf, "repo1-retention-full=14") &&
      strcontains(module.monitoring.pgbackrest_conf, "repo1-path=/lylat-pg18\n") &&
      strcontains(module.monitoring.pgbackrest_conf, "[lylat-pg18]\npg1-path=/var/lib/postgresql/patroni/18\n") &&
      !strcontains(module.monitoring.pgbackrest_conf, "MOCKPGKEY") &&
      strcontains(nonsensitive(module.monitoring.postgres_deployments.pg01), base64encode("PGBACKREST_REPO1_S3_KEY=MOCKPGKEY\nPGBACKREST_REPO1_S3_KEY_SECRET=mockpgsecretmockpgsecret\n"))
    )
    error_message = "pgBackRest uses bucket postgres via https://127.0.0.1:7443, 14 days of PITR, S3 keys from s3.env."
  }

  assert {
    # Packages, services in order, Patroni reloaded (never restarted) by deploys.
    condition = (
      strcontains(module.monitoring.postgres_packages_script, "for pkg in keepalived jq postgresql-18 patroni python3-etcd etcd-server etcd-client pgbackrest; do") &&
      # The deploy runs the staged package script before its checks, and installs it.
      strcontains(nonsensitive(module.monitoring.postgres_deployments.pg01), "\nbash \"$stage/usr/local/sbin/pg-packages\" \"$stage\"\n") &&
      strcontains(nonsensitive(module.monitoring.postgres_deployments.pg01), "unpack '/usr/local/sbin/pg-packages' '${base64encode(module.monitoring.postgres_packages_script)}'") &&
      strcontains(nonsensitive(module.monitoring.postgres_deployments.pg01), "put '/usr/local/sbin/pg-packages' '0755' '0:0' reload \n") &&
      strcontains(nonsensitive(module.monitoring.postgres_deployments.pg01), "for unit in postgres-guard haproxy etcd patroni pg-leader-setup postgres-exporter alloy node-exporter keepalived; do") &&
      strcontains(nonsensitive(module.monitoring.postgres_deployments.pg01), "put '/etc/patroni/config.yml' '0644' '0:0' reload patroni\n") &&
      strcontains(nonsensitive(module.monitoring.postgres_deployments.pg01), "put '/etc/postgres-ha/patroni.env' '0600' '0:0' reload \n") &&
      strcontains(nonsensitive(module.monitoring.postgres_deployments.pg01), "pg_dropcluster --stop 18 main") &&
      strcontains(module.monitoring.units.pg01["postgres-exporter"], "HealthCmd=wget -q -O /dev/null http://10.55.14.40:9187/\n") &&
      strcontains(nonsensitive(module.monitoring.postgres_deployments.pg01), "case $v in 18.6-*)") &&
      strcontains(nonsensitive(module.monitoring.postgres_deployments.pg01), "case $v in 4.1.5-*)") &&
      strcontains(nonsensitive(module.monitoring.postgres_deployments.pg01), "case $v in 2.60.0-*)") &&
      !strcontains(nonsensitive(module.monitoring.postgres_deployments.pg01), "postgresql-17") &&
      !strcontains(nonsensitive(module.monitoring.postgres_deployments.pg01), "/17/")
    )
    error_message = "The deploy installs the packages (PostgreSQL 18), starts guard -> etcd -> Patroni -> keepalived and only reloads Patroni."
  }

  assert {
    # PGDG: source + pin + key installed (and apt lists refreshed) before any package, outside
    # versions upgraded, and package scripts can't (re)start a service (policy-rc.d) meanwhile.
    condition = (
      strcontains(nonsensitive(module.monitoring.postgres_deployments.pg01), base64encode(file("../../modules/services/monitoring/templates/pgdg.asc"))) &&
      strcontains(nonsensitive(module.monitoring.postgres_deployments.pg01), "put '/etc/apt/sources.list.d/pgdg.sources' '0644' '0:0' reload \n") &&
      strcontains(module.monitoring.postgres_packages_script, "for f in /etc/apt/keyrings/pgdg.asc /etc/apt/preferences.d/pgdg.pref /etc/apt/sources.list.d/pgdg.sources; do") &&
      strcontains(module.monitoring.postgres_packages_script, "for spec in 'etcd-client=3.5.16-*' 'etcd-server=3.5.16-*' 'patroni=4.1.5-*' 'pgbackrest=2.60.0-*' 'postgresql-18=18.6-*' 'postgresql-client-18=18.6-*'; do") &&
      # A missing or off-pin package installs exactly the newest apt version matching its pin.
      strcontains(module.monitoring.postgres_packages_script, "'postgresql-18') echo '18.6-*' ;;") &&
      strcontains(module.monitoring.postgres_packages_script, "targets+=\" $pkg=$ver\"") &&
      strcontains(module.monitoring.postgres_packages_script, "printf '#!/bin/sh\\nexit 101\\n' > \"$policy_rc\"") &&
      strcontains(nonsensitive(module.monitoring.postgres_deployments.pg01), base64encode(<<-EOT
        # Managed by OpenTofu (monitoring-config). Local edits are overwritten.
        # PGDG supplies the Patroni stack only; every other package stays Debian's.
        Package: *
        Pin: release o=apt.postgresql.org
        Pin-Priority: 100

        Package: postgresql-18 postgresql-client-18 postgresql-common postgresql-client-common libpq5 patroni pgbackrest
        Pin: release o=apt.postgresql.org
        Pin-Priority: 600
      EOT
      )) &&
      strcontains(module.monitoring.postgres_packages_script, "[ \"$codename-pgdg\" = 'trixie-pgdg' ]") &&
      # The other roles' deploys have no PGDG step: keepalived comes from the shared deploy's package list.
      !strcontains(nonsensitive(module.monitoring.backend_deployments.mon01), "policy-rc.d") &&
      strcontains(nonsensitive(module.monitoring.backend_deployments.mon01), "dpkg-query -W -f='$${Status}' 'keepalived'")
    )
    error_message = "The Postgres deploy sets up the PGDG repository (pinned to the Patroni stack) before installing, upgrades packages outside their series and keeps package scripts from starting services."
  }

  assert {
    condition = (
      length([for j in yamldecode(module.monitoring.prometheus_config).scrape_configs : j if contains(["patroni", "etcd", "postgres", "haproxy-postgres"], j.job_name)]) == 4 &&
      strcontains(module.monitoring.prometheus_config, "10.56.14.40:8008") &&
      strcontains(module.monitoring.prometheus_config, "10.56.14.42:2381") &&
      strcontains(module.monitoring.prometheus_config, "10.55.14.41:9187") && # postgres_exporter over lylat-telemetry
      length([for g in yamldecode(module.monitoring.prometheus_rules).groups : g if g.name == "postgres"]) == 1 &&
      strcontains(module.monitoring.prometheus_rules, "PatroniNoLeader") &&
      strcontains(module.monitoring.prometheus_rules, "PostgresWALArchiveFailing") &&
      strcontains(module.monitoring.prometheus_rules, "EtcdQuorumLost") &&
      strcontains(module.monitoring.prometheus_rules, "address=\\\"10.56.14.104\\\"") &&
      length([for t in local.targets.node : t if t.labels == { role = "postgres" }]) == 3
    )
    error_message = "Both Prometheus replicas scrape Patroni, etcd, postgres_exporter and haproxy on pg01-03, with the postgres alert group."
  }

  assert {
    condition = (
      output.grafana_db_host == "10.56.14.104:5432" &&
      strcontains(module.monitoring.units.graf01.grafana, "GF_DATABASE_HOST=10.56.14.104:5432") &&
      strcontains(module.monitoring.units.graf02.grafana, "GF_DATABASE_SSL_MODE=require") &&
      !contains(keys(module.monitoring.units.mon01), "postgres") &&
      !strcontains(nonsensitive(module.monitoring.backend_deployments.mon01), "pg_isready") &&
      !contains(module.monitoring.backend_services_by_host.mon01, "postgres")
    )
    error_message = "Grafana's database is the Patroni VIP (TLS required); mon01 runs no Postgres."
  }
}

run "postgres_needs_s3_keys" {
  command = plan

  variables {
    postgres_s3 = null
  }

  assert {
    condition = (
      length(terraform_data.postgres) == 0 &&
      output.postgres_vip == null &&
      !strcontains(module.monitoring.prometheus_config, "job_name: patroni")
    )
    error_message = "Without postgres_s3 the cluster is left out."
  }

  # Grafana has no database without the cluster.
  expect_failures = [check.postgres_s3, terraform_data.grafana]
}

run "postgres_bootstrap_from_backup" {
  command = plan

  variables {
    postgres_settings = { bootstrap_from_backup = true, restore_target_time = "2026-11-20 12:00:00+00" }
  }

  assert {
    condition = (
      yamldecode(module.monitoring.patroni_configs.pg01).bootstrap.method == "pgbackrest" &&
      yamldecode(module.monitoring.patroni_configs.pg01).bootstrap.pgbackrest.command == "pgbackrest --stanza=lylat-pg18 --delta --type=time '--target=2026-11-20 12:00:00+00' --target-action=promote restore" &&
      yamldecode(module.monitoring.patroni_configs.pg01).bootstrap.pgbackrest.keep_existing_recovery_conf == true &&
      !can(yamldecode(module.monitoring.patroni_configs.pg02).bootstrap.dcs.method)
    )
    error_message = "bootstrap_from_backup makes Patroni restore the cluster from pgBackRest (point in time) instead of initdb."
  }
}

run "postgres_bootstrap_default_initdb" {
  command = plan

  assert {
    condition     = !can(yamldecode(module.monitoring.patroni_configs.pg01).bootstrap.method)
    error_message = "By default Patroni bootstraps with initdb."
  }
}

run "postgres_major_override" {
  command = plan

  variables {
    packages = { postgresql = "19.1", patroni = "4.2.0", etcd = "3.5.16", pgbackrest = "2.61.0-1.pgdg13+1" }
  }

  assert {
    condition = (
      yamldecode(module.monitoring.patroni_configs.pg01).scope == "lylat-pg19" &&
      yamldecode(module.monitoring.patroni_configs.pg01).postgresql.data_dir == "/var/lib/postgresql/patroni/19" &&
      yamldecode(module.monitoring.etcd_configs.pg01).data-dir == "/var/lib/etcd/lylat-pg" &&
      strcontains(module.monitoring.postgres_packages_script, "'patroni=4.2.0-*' 'pgbackrest=2.61.0-1.pgdg13+1' 'postgresql-19=19.1-*' 'postgresql-client-19=19.1-*'; do") &&
      strcontains(module.monitoring.postgres_packages_script, "'etcd-server') echo '3.5.16-*' ;;")
    )
    error_message = "packages.postgresql's major selects the packages, data dir, Patroni scope and stanza; an upstream version accepts any Debian revision, a full version only itself."
  }
}

run "postgres_major_invalid" {
  command = plan

  variables {
    packages = { postgresql = "16.5", patroni = "4.1.5", etcd = "3.5.16", pgbackrest = "2.60.0" }
  }

  expect_failures = [var.packages]
}
