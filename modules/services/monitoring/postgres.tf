# Postgres HA for Grafana: a Patroni cluster on the role = "postgres" VMs (pg01-03).
#
# Each member runs, from packages: PostgreSQL 18 (Patroni owns the process and the data
# directory), Patroni, etcd (the DCS: 3 members, peers and clients on the Postgres HA
# VLAN), pgBackRest (WAL archive + daily full backups in a Ceph RGW bucket, PITR) and
# keepalived (the VIP on the backend VLAN follows the Patroni leader: its check is Patroni's
# /primary). In containers (Quadlet), like the other roles: haproxy (TLS on 127.0.0.1:7443 ->
# the RGWs, because pgBackRest only speaks HTTPS to S3), postgres_exporter, node_exporter
# (with the textfile collector for the backup result) and Alloy (journal -> Loki).
#
# Why packages and not containers for the database: Patroni has to start and stop Postgres
# itself and archive_command has to find pgBackRest next to it, so they belong in one place.
# The only maintained image with all three is Spilo (Kubernetes-oriented, configured through
# generated env, its own cron/WAL-G, several Postgres majors in ~1.5 GB). etcd (3.5) comes
# from Debian 13; PostgreSQL 18, Patroni 4.1 and pgBackRest 2.60 from the PGDG repository
# (apt.postgresql.org; Debian 13 has PostgreSQL 17 only), pinned to exactly those packages
# (pgdg.pref). The versions come from packages in inventory/auto.tfvars/software-versions.auto.tfvars
# (postgres_settings.package_versions): a package missing or outside its pin is installed at the
# newest apt version matching it, the deploy fails if none does, and unattended-upgrades leaves
# the stack alone. Running services keep the old binaries until restarted (rolling minor upgrade).
#
# A new major (the major of packages.postgresql -> postgres_settings.pg_major) is a rebuild: its own Patroni scope and pgBackRest
# stanza ("<cluster_name><pg_major>", e.g. lylat-pg18) and data dir, so the old cluster's etcd
# keys, backups and data stay untouched for a rollback; the data moves by dump/restore
# (17 -> 18: DT-046). etcd keeps cluster_name (its data dir and cluster token).
#
# Grafana's database is on this cluster (the VIP, TLS required). mon01's old Postgres container
# (Grafana's database until the 2026-11-10 cutover) was removed from the code on 2026-11-14.

locals {
  pg_conf     = "/etc/postgres-ha"
  pg_major    = local.pgs.pg_major
  pg_data_dir = "/var/lib/postgresql/patroni/${local.pg_major}"
  pg_bin_dir  = "/usr/lib/postgresql/${local.pg_major}/bin"
  pg_textfile = "/var/lib/node_exporter/textfile"

  postgres_enabled = length(var.postgres) > 0 && nonsensitive(var.postgres_secrets != null)
  pg_secrets = local.postgres_enabled ? var.postgres_secrets : {
    s3_bucket        = "", s3_access_key = "", s3_secret_key = "", superuser_password = "", replication_password = ""
    restapi_password = "", monitor_password = ""
  }
  pg_names = sort(keys(var.postgres))
  pgs      = var.postgres_settings
  # Patroni's synchronous_mode value: the string "quorum" or a YAML bool ("on"/"off" strings aren't accepted).
  pg_sync_yaml = { quorum = "quorum", on = "true", off = "false" }[var.postgres_settings.synchronous_mode]
  pg_vip       = split("/", local.pgs.vip)[0]
  pg_scope     = "${local.pgs.cluster_name}${local.pg_major}" # Patroni scope, pgBackRest stanza and repo path
  etcd_scope   = local.pgs.cluster_name                       # etcd data dir and cluster token: unchanged across majors

  # Grafana (main.tf): always this cluster's VIP.
  grafana_db_host = "${local.pg_vip}:5432"
  grafana_db_env  = { GF_DATABASE_SSL_MODE = "require" }

  pg_priority = { for i, name in local.pg_names : name => max(150 - 50 * i, 10) }
  pg_members  = [for name in local.pg_names : var.postgres[name].ha_address]
  # Grafana connects from its backend-VLAN address (its container is masqueraded by the host),
  # Prometheus from the backends' backend-VLAN addresses.
  pg_grafana_clients = sort([for g in values(var.grafana) : g.backend_address])
  pg_app_clients     = sort(distinct(flatten([for a in values(var.postgres_apps) : a.clients])))
  pg_grafana_apps    = sort([for app, a in var.postgres_apps : app if length(a.grafana_grants) > 0])
  pg_scrapers        = sort([for b in values(var.backends) : b.backend_address])

  pgbackrest = "pgbackrest --stanza=${local.pg_scope}"

  # Disaster recovery (every member lost, etcd empty): the first member bootstraps from the
  # pgBackRest repository instead of initdb (same system id, so archiving continues on a new
  # timeline), optionally to a point in time. Only read while etcd has no initialize key.
  pg_bootstrap_restore = { for k, v in {
    method = "pgbackrest"
    pgbackrest = {
      command = join(" ", concat([local.pgbackrest, "--delta"],
        local.pgs.restore_target_time == null ? [] : ["--type=time", "'--target=${local.pgs.restore_target_time}'", "--target-action=promote"],
      ["restore"]))
      keep_existing_recovery_conf = true
      no_params                   = true
    }
  } : k => v if local.pgs.bootstrap_from_backup }

  # --- Patroni, one config per member (no secrets: passwords come from patroni.env) ---
  patroni_yml = {
    for name, vm in var.postgres : name => yamlencode({
      scope     = local.pg_scope
      namespace = "/service/"
      name      = name
      log       = { level = "INFO" } # stderr -> journal

      restapi = {
        # Every address: Prometheus scrapes /metrics on the backend VLAN, keepalived checks
        # /primary on loopback, the members talk over the HA VLAN. postgres-guard limits it;
        # unsafe endpoints (POST/PATCH/DELETE) need the credentials from patroni.env.
        listen          = "0.0.0.0:8008"
        connect_address = "${vm.ha_address}:8008"
      }

      etcd3 = {
        hosts    = [for peer in local.pg_names : "${var.postgres[peer].ha_address}:2379"]
        protocol = "http"
      }

      bootstrap = merge({
        # Initial dynamic configuration (in etcd). Later changes: sudo pgctl edit-config.
        dcs = {
          ttl                     = 30
          loop_wait               = 10
          retry_timeout           = 10
          maximum_lag_on_failover = local.pgs.maximum_lag_on_failover
          # The leader keeps running through an etcd outage if it still reaches every member.
          failsafe_mode = true
          # Synchronous replication (postgres_settings.synchronous_mode). Bootstrap only; the running cluster gets it
          # from pg-leader-setup (patronictl edit-config) on every deploy.
          synchronous_mode        = jsondecode(local.pg_sync_yaml == "quorum" ? "\"quorum\"" : local.pg_sync_yaml)
          synchronous_node_count  = local.pgs.synchronous_node_count
          synchronous_mode_strict = false
          postgresql = {
            use_pg_rewind = true
            use_slots     = true
            # Cluster-wide parameters (Patroni takes these from etcd only).
            parameters = {
              max_connections       = local.pgs.max_connections
              wal_level             = "replica"
              hot_standby           = "on"
              wal_log_hints         = "on"
              max_wal_senders       = 10
              max_replication_slots = 10
              wal_keep_size         = "1GB"
            }
          }
        }
        initdb = [
          { encoding = "UTF8" },
          { locale = "C.UTF-8" },
          { "locale-provider" = "builtin" }, # no glibc collation-version drift between members
          "data-checksums",
        ]
      }, local.pg_bootstrap_restore)

      postgresql = {
        # Every address, so the VIP works on whichever member leads; postgres-guard and pg_hba limit it.
        listen          = "0.0.0.0:5432"
        connect_address = "${vm.ha_address}:5432" # replication and pg_rewind over the HA VLAN
        data_dir        = local.pg_data_dir
        bin_dir         = local.pg_bin_dir
        pgpass          = "/var/lib/postgresql/.pgpass.patroni"
        use_unix_socket = true
        authentication = {
          superuser   = { username = "postgres" }
          replication = { username = "replicator" }
        }
        # Local parameters win over the dynamic ones and follow tofu (SIGHUP; restart-only ones
        # show up as pending_restart: sudo pgctl restart <scope> <member>, one at a time).
        parameters = merge({
          unix_socket_directories = "/var/run/postgresql"
          password_encryption     = "scram-sha-256"
          ssl                     = "on"
          ssl_cert_file           = "/etc/ssl/certs/ssl-cert-snakeoil.pem"
          ssl_key_file            = "/etc/ssl/private/ssl-cert-snakeoil.key"
          archive_mode            = "on"
          archive_command         = "${local.pgbackrest} archive-push %p"
          archive_timeout         = local.pgs.archive_timeout
          shared_buffers          = "1GB"
          effective_cache_size    = "3GB"
          log_line_prefix         = "%m [%p] %q%u@%d "
          log_connections         = "off"
        }, local.pgs.parameters)
        recovery_conf = {
          # Replicas that fall behind the leader's WAL catch up from the archive.
          restore_command = "${local.pgbackrest} archive-get %f \"%p\""
        }
        create_replica_methods = ["basebackup"]
        basebackup             = [{ checkpoint = "fast" }]
        pg_hba = concat(
          [
            "local all postgres peer",
            "local replication postgres peer",
            "host all pgmon 127.0.0.1/32 scram-sha-256", # postgres_exporter
            # Patroni's own replication connection to the local Postgres (IDENTIFY_SYSTEM: local
            # timeline/LSN for pg_rewind decisions). With listen 0.0.0.0 Patroni connects to
            # 127.0.0.1; the Patroni docs require this loopback line for replication.
            "host replication replicator 127.0.0.1/32 scram-sha-256",
          ],
          [for ip in local.pg_members : "host replication replicator ${ip}/32 scram-sha-256"],
          [for ip in local.pg_members : "host all postgres ${ip}/32 scram-sha-256"], # pg_rewind, Patroni
          [for ip in local.pg_grafana_clients : "hostssl grafana grafana ${ip}/32 scram-sha-256"],
          flatten([for app, a in var.postgres_apps : [for ip in a.clients : "hostssl ${app} ${app} ${ip}/32 scram-sha-256"]]),
          flatten([for app in local.pg_grafana_apps : [for ip in local.pg_grafana_clients : "hostssl ${app} ${app}_grafana ${ip}/32 scram-sha-256"]]),
        )
      }

      watchdog = { mode = "automatic", device = "/dev/watchdog", safety_margin = 5 }
      tags     = { nofailover = false, noloadbalance = false, clonefrom = false, nosync = false }
    })
  }

  patroni_env = local.postgres_enabled ? join("", [
    "PATRONI_SUPERUSER_PASSWORD=${local.pg_secrets.superuser_password}\n",
    "PATRONI_REPLICATION_PASSWORD=${local.pg_secrets.replication_password}\n",
    "PATRONI_RESTAPI_USERNAME=patroni\n",
    "PATRONI_RESTAPI_PASSWORD=${local.pg_secrets.restapi_password}\n",
    "PATRONI_CTL_USERNAME=patroni\n",
    "PATRONI_CTL_PASSWORD=${local.pg_secrets.restapi_password}\n",
  ]) : ""
  pg_s3_env = local.postgres_enabled ? "PGBACKREST_REPO1_S3_KEY=${local.pg_secrets.s3_access_key}\nPGBACKREST_REPO1_S3_KEY_SECRET=${local.pg_secrets.s3_secret_key}\n" : ""
  pg_roles_env = local.postgres_enabled ? join("", concat(
    ["PG_GRAFANA_PASSWORD=${var.secrets.grafana_db_password}\n", "PG_MONITOR_PASSWORD=${local.pg_secrets.monitor_password}\n"],
    [for app in keys(var.postgres_apps) : "PG_APP_${upper(app)}_PASSWORD=${var.postgres_app_passwords[app]}\n"],
    [for app in local.pg_grafana_apps : "PG_APP_${upper(app)}_GRAFANA_PASSWORD=${var.postgres_app_passwords["${app}_grafana"]}\n"],
  )) : ""
  pg_exporter_env = local.postgres_enabled ? (
    "DATA_SOURCE_NAME=postgresql://pgmon:${urlencode(local.pg_secrets.monitor_password)}@127.0.0.1:5432/postgres?sslmode=disable\n"
  ) : ""

  # --- etcd, one per member ---
  etcd_yml = {
    for name, vm in var.postgres : name => yamlencode({
      name                        = name
      data-dir                    = "/var/lib/etcd/${local.etcd_scope}"
      listen-peer-urls            = "http://${vm.ha_address}:2380"
      listen-client-urls          = "http://${vm.ha_address}:2379,http://127.0.0.1:2379"
      advertise-client-urls       = "http://${vm.ha_address}:2379"
      initial-advertise-peer-urls = "http://${vm.ha_address}:2380"
      initial-cluster             = join(",", [for peer in local.pg_names : "${peer}=http://${var.postgres[peer].ha_address}:2380"])
      initial-cluster-token       = local.etcd_scope
      # "new" bootstraps the three together; a rebuilt member joins with "existing" (README).
      initial-cluster-state = local.pgs.etcd_initial_cluster_state
      # Slow disk: the data dir is on Ceph RBD, where WAL fsync p99 is 125-355 ms (etcd wants < 10 ms).
      # The defaults (100/1000 ms) made leaders miss heartbeats hourly and re-elect (DT-017). The etcd
      # tuning guide: heartbeat ~ the fsync/round-trip time, election ~ 10x the heartbeat. Patroni
      # (ttl 30 s, loop_wait 10 s) easily rides out a 3 s election. Same values on every member.
      heartbeat-interval        = local.pgs.etcd_heartbeat_interval
      election-timeout          = local.pgs.etcd_election_timeout
      listen-metrics-urls       = "http://${vm.backend_address}:2381"
      auto-compaction-mode      = "periodic"
      auto-compaction-retention = "1h"
      enable-v2                 = false
      log-outputs               = ["stderr"]
    })
  }

  pgbackrest_conf = <<-EOT
    # Managed by OpenTofu (monitoring-config). Local edits are overwritten.
    # S3 keys: PGBACKREST_REPO1_S3_KEY / _KEY_SECRET from /etc/postgres-ha/s3.env (Patroni's and
    # pg-backup's environment). Retention: full backups kept so that PITR reaches back
    # ${local.pgs.retention_days} days; expire prunes the WAL archive with them.
    [global]
    repo1-type=s3
    repo1-s3-endpoint=127.0.0.1
    repo1-storage-port=7443
    repo1-storage-verify-tls=n
    repo1-s3-bucket=${local.pg_secrets.s3_bucket}
    repo1-s3-region=default
    repo1-s3-uri-style=path
    repo1-path=/${local.pg_scope}
    repo1-retention-full-type=time
    repo1-retention-full=${local.pgs.retention_days}
    compress-type=zst
    start-fast=y
    process-max=2
    log-level-console=info
    log-level-file=off

    [${local.pg_scope}]
    pg1-path=${local.pg_data_dir}
    pg1-socket-path=/var/run/postgresql
    pg1-port=5432
  EOT

  pg_keepalived_conf = {
    for name, vm in var.postgres : name => templatefile("${path.module}/templates/postgres-keepalived.conf.tftpl", {
      host          = name
      router_id     = local.pgs.vrrp_router_id
      priority      = local.pg_priority[name]
      ha_interface  = vm.interfaces.ha
      ha_address    = vm.ha_address
      peers         = [for peer in local.pg_names : var.postgres[peer].ha_address if peer != name]
      vip           = local.pgs.vip
      vip_interface = vm.interfaces.backend
    })
  }

  pg_haproxy_cfg = {
    for name, vm in var.postgres : name => templatefile("${path.module}/templates/postgres-haproxy.cfg.tftpl", {
      host          = name
      endpoints     = local.pgs.rgw_endpoints
      stats_address = vm.backend_address
    })
  }

  pg_guard_nft = templatefile("${path.module}/templates/postgres-guard.nft.tftpl", {
    clients  = local.pg_grafana_clients
    apps     = local.pg_app_clients
    members  = local.pg_members
    scrapers = local.pg_scrapers
  })

  pg_alloy_hosts = local.postgres_enabled ? {
    for name, vm in var.postgres : name => { listen = coalesce(vm.telemetry_address, vm.backend_address), loki_url = local.loki_push_url, syslog = false }
  } : {}

  pg_units = {
    for name, vm in var.postgres : name => {
      # User=0: reads the key, then drops to haproxy (global user/group).
      haproxy = templatefile("${path.module}/templates/postgres-haproxy.container.tftpl", { image = var.images.haproxy })
      # Off by default, used by the Databases dashboards: pg_stat_checkpointer (PG 17+ moved the
      # checkpoint counters out of pg_stat_bgwriter), postmaster start time, transactions open
      # > 1 min, xid/multixact age per database.
      postgres-exporter = templatefile("${path.module}/templates/postgres-exporter.container.tftpl", {
        image          = var.images.postgres_exporter
        listen_address = coalesce(vm.telemetry_address, vm.backend_address)
      })
      # address-info: which VM holds the VIP; textfile: pg-backup's result.
      node-exporter = templatefile("${path.module}/templates/node-exporter.container.tftpl", {
        image          = var.images.node_exporter
        listen_address = coalesce(vm.telemetry_address, vm.backend_address)
        textfile_dir   = local.pg_textfile
      })
    }
  }

  pg_packages = ["keepalived", "jq", "postgresql-${local.pg_major}", "patroni", "python3-etcd", "etcd-server", "etcd-client", "pgbackrest"]
  # Debian package => dpkg glob, from software-versions.auto.tfvars (the root maps names to packages).
  pg_package_versions = local.pgs.package_versions

  # PGDG (apt.postgresql.org): only the Patroni stack comes from it (priority 600); every other
  # PGDG package stays below Debian's (100), so it never replaces a Debian package by accident.
  # The key (templates/pgdg.asc) is fingerprint B97B 0AFC AA1A 47F0 44F2 44A0 7FCC 7D46 ACCC 4CF8.
  pg_apt_suite = "trixie-pgdg" # Debian 13 (the deploy checks the codename)
  pg_pgdg_packages = [
    "postgresql-${local.pg_major}", "postgresql-client-${local.pg_major}", "postgresql-common", "postgresql-client-common",
    "libpq5", "patroni", "pgbackrest",
  ]
  pg_apt_files = {
    "/etc/apt/keyrings/pgdg.asc"           = file("${path.module}/templates/pgdg.asc")
    "/etc/apt/sources.list.d/pgdg.sources" = <<-EOT
      # Managed by OpenTofu (monitoring-config). Local edits are overwritten.
      # PostgreSQL Global Development Group: PostgreSQL ${local.pg_major}, Patroni, pgBackRest (pgdg.pref).
      Types: deb
      URIs: https://apt.postgresql.org/pub/repos/apt
      Suites: ${local.pg_apt_suite}
      Components: main
      Signed-By: /etc/apt/keyrings/pgdg.asc
    EOT
    "/etc/apt/preferences.d/pgdg.pref"     = <<-EOT
      # Managed by OpenTofu (monitoring-config). Local edits are overwritten.
      # PGDG supplies the Patroni stack only; every other package stays Debian's.
      Package: *
      Pin: release o=apt.postgresql.org
      Pin-Priority: 100

      Package: ${join(" ", local.pg_pgdg_packages)}
      Pin: release o=apt.postgresql.org
      Pin-Priority: 600
    EOT
  }
  # The packages above (pins from postgres_settings.package_versions), PGDG apt files first: its own script,
  # installed as /usr/local/sbin/pg-packages; the deploy runs the staged copy before its checks.
  pg_packages_script = templatefile("${path.module}/templates/pg-packages.sh.tftpl", {
    suite     = local.pg_apt_suite
    apt_files = keys(local.pg_apt_files)
    packages  = local.pg_packages
    versions  = local.pg_package_versions
  })

  # Start order: the guard before anything listens, S3 before Patroni (archive_command),
  # etcd before Patroni, the leader setup once Postgres runs, keepalived last.
  pg_services = ["postgres-guard", "haproxy", "etcd", "patroni", "pg-leader-setup", "postgres-exporter", "alloy", "node-exporter", "keepalived"]

  pg_version_checks = [
    for pkg, pattern in local.pg_package_versions :
    "if v=$(dpkg-query -W -f='$${Version}' ${pkg} 2>/dev/null); then case $v in ${pattern}) ;; *) echo \"${pkg} $v is not ${pattern} (software-versions.auto.tfvars)\" >&2; exit 1 ;; esac; fi"
  ]

  pg_files = {
    for name, vm in var.postgres : name => concat(
      [for path, content in local.pg_apt_files : { path = path, content = content }],
      [{ path = "/usr/local/sbin/pg-packages", mode = "0755", content = local.pg_packages_script }],
      [for unit in ["haproxy", "postgres-exporter", "node-exporter"] : { path = "${local.quadlet_dir}/${unit}.container", content = local.pg_units[name][unit], units = [unit] }],
      lookup(local.alloy_files, name, []),
      [
        { path = "${local.pg_conf}/haproxy/haproxy.cfg", content = local.pg_haproxy_cfg[name], units = ["haproxy"], restart = true },
        { path = "${local.pg_conf}/guard.nft", content = local.pg_guard_nft, units = ["postgres-guard"], restart = true },
        { path = "/etc/systemd/system/postgres-guard.service", content = file("${path.module}/templates/postgres-guard.service"), units = ["postgres-guard"] },
        # etcd: one member restarting keeps quorum; apply with -parallelism=1 for a rolling change.
        { path = "/etc/etcd/etcd.yml", content = local.etcd_yml[name], units = ["etcd"], restart = true },
        { path = "/etc/systemd/system/etcd.service.d/lylat.conf", content = file("${path.module}/templates/etcd-dropin.conf"), units = ["etcd"], restart = true },
        # Patroni is never restarted by a deploy (that would stop Postgres, and fail over on the
        # leader): config changes are a SIGHUP (its unit's ExecReload); env/unit changes need a rolling restart (README).
        { path = "/etc/patroni/config.yml", content = local.patroni_yml[name], units = ["patroni"] },
        { path = "${local.pg_conf}/patroni.env", mode = "0600", content = local.patroni_env },
        { path = "${local.pg_conf}/s3.env", mode = "0600", content = local.pg_s3_env },
        { path = "/etc/systemd/system/patroni.service.d/lylat.conf", content = file("${path.module}/templates/patroni-dropin.conf") },
        { path = "${local.pg_conf}/roles.env", mode = "0600", content = local.pg_roles_env, units = ["pg-leader-setup"], restart = true },
        { path = "/usr/local/sbin/pg-leader-setup", mode = "0755", content = templatefile("${path.module}/templates/pg-leader-setup.sh.tftpl", { name = name, stanza = local.pg_scope, sync_mode = local.pg_sync_yaml, sync_count = local.pgs.synchronous_node_count, apps = sort(keys(var.postgres_apps)), grafana = { for app in local.pg_grafana_apps : app => var.postgres_apps[app].grafana_grants } }), units = ["pg-leader-setup"], restart = true },
        { path = "/etc/systemd/system/pg-leader-setup.service", content = file("${path.module}/templates/pg-leader-setup.service"), units = ["pg-leader-setup"] },
        { path = "/etc/pgbackrest/pgbackrest.conf", content = local.pgbackrest_conf },
        { path = "/usr/local/sbin/pg-backup", mode = "0755", content = templatefile("${path.module}/templates/pg-backup.sh.tftpl", { stanza = local.pg_scope, textfile_dir = local.pg_textfile }) },
        { path = "/etc/systemd/system/pg-backup.service", content = file("${path.module}/templates/pg-backup.service") },
        { path = "/etc/systemd/system/pg-backup.timer", content = templatefile("${path.module}/templates/pg-backup.timer.tftpl", { schedule = local.pgs.backup_schedule }) },
        { path = "/usr/local/sbin/pgctl", mode = "0755", content = templatefile("${path.module}/templates/pgctl.sh.tftpl", { scope = local.pg_scope }) },
        { path = "${local.pg_conf}/postgres-exporter.env", mode = "0600", content = local.pg_exporter_env, units = ["postgres-exporter"], restart = true },
        { path = "/etc/apt/apt.conf.d/51lylat-postgres-hold", content = templatefile("${path.module}/templates/postgres-apt-hold.conf.tftpl", { packages = distinct(concat(local.pg_pgdg_packages, ["python3-etcd", "etcd-server", "etcd-client"])) }) },
        { path = "/etc/keepalived/keepalived.conf", mode = "0600", content = local.pg_keepalived_conf[name], units = ["keepalived"] },
      ],
    )
  }

  # --- Prometheus: scrape jobs, alerts ---
  postgres_scrape_configs = local.postgres_enabled ? [
    {
      job_name       = "patroni"
      static_configs = [for name in local.pg_names : { targets = ["${var.postgres[name].backend_address}:8008"], labels = { host = name } }]
    },
    {
      job_name       = "etcd"
      static_configs = [for name in local.pg_names : { targets = ["${var.postgres[name].backend_address}:2381"], labels = { host = name } }]
    },
    {
      job_name       = "postgres"
      static_configs = [for name in local.pg_names : { targets = ["${coalesce(var.postgres[name].telemetry_address, var.postgres[name].backend_address)}:9187"], labels = { host = name } }]
    },
    {
      job_name       = "haproxy-postgres"
      static_configs = [for name in local.pg_names : { targets = ["${var.postgres[name].backend_address}:8405"], labels = { host = name } }]
    },
  ] : []

  postgres_rules = local.postgres_enabled ? [{
    name = "postgres"
    rules = [
      {
        alert       = "PatroniNoLeader"
        expr        = "sum(patroni_primary{job=\"patroni\"}) != 1 or absent(patroni_primary{job=\"patroni\"})"
        for         = "1m"
        labels      = { severity = "critical" }
        annotations = { summary = "The Patroni cluster ${local.pg_scope} has {{ $value }} leaders instead of exactly one: Grafana's database is unavailable or split" }
      },
      {
        alert       = "PatroniMembersMissing"
        expr        = "count(patroni_postgres_running{job=\"patroni\"} == 1) < ${length(var.postgres)} or absent(patroni_postgres_running{job=\"patroni\"} == 1)"
        for         = "5m"
        labels      = { severity = "warning" }
        annotations = { summary = "Fewer than ${length(var.postgres)} Patroni members run Postgres" }
      },
      {
        alert       = "PatroniReplicaNotStreaming"
        expr        = "patroni_replica{job=\"patroni\"} == 1 and on (host) patroni_postgres_streaming{job=\"patroni\"} == 0"
        for         = "5m"
        labels      = { severity = "warning" }
        annotations = { summary = "Postgres replica {{ $labels.host }} is not streaming from the leader" }
      },
      {
        alert       = "PatroniReplicaLag"
        expr        = "(scalar(max(patroni_xlog_location{job=\"patroni\"} and on (host) patroni_primary{job=\"patroni\"} == 1)) - (patroni_xlog_replayed_location{job=\"patroni\"} and on (host) patroni_replica{job=\"patroni\"} == 1)) > ${local.pgs.maximum_lag_on_failover}"
        for         = "5m"
        labels      = { severity = "warning" }
        annotations = { summary = "Postgres replica {{ $labels.host }} is {{ $value | humanize1024 }}B behind the leader (no longer a failover candidate)" }
      },
      {
        # Synchronous replication is configured but no replica is a sync/quorum standby: commits run async, so a
        # failover can lose the last commits. Normal for a few seconds while a replica restarts.
        alert       = "PatroniNoSyncStandby"
        expr        = "${local.pgs.synchronous_mode == "off" ? "vector(0) == 1" : "(sum(patroni_sync_standby{job=\"patroni\"}) + sum(patroni_quorum_standby{job=\"patroni\"})) == 0 and on () count(patroni_primary{job=\"patroni\"} == 1) == 1"}"
        for         = "5m"
        labels      = { severity = "warning" }
        annotations = { summary = "Postgres has no synchronous standby (synchronous_mode ${local.pgs.synchronous_mode}): commits are async, a failover can lose the latest commits" }
      },
      {
        alert       = "PatroniPendingRestart"
        expr        = "patroni_pending_restart{job=\"patroni\"} == 1"
        for         = "1h"
        labels      = { severity = "info" }
        annotations = { summary = "Postgres on {{ $labels.host }} needs a restart for a changed parameter (sudo pgctl restart ${local.pg_scope} {{ $labels.host }})" }
      },
      {
        alert       = "PostgresWALArchiveFailing"
        expr        = "increase(pg_stat_archiver_failed_count{job=\"postgres\"}[15m]) > 0 and on (host) patroni_primary{job=\"patroni\"} == 1"
        for         = "5m"
        labels      = { severity = "critical" }
        annotations = { summary = "The Postgres leader {{ $labels.host }} fails to archive WAL to S3 (pgBackRest): PITR is broken and pg_wal grows" }
      },
      {
        alert       = "PostgresWALArchiveStale"
        expr        = "pg_stat_archiver_last_archive_age{job=\"postgres\"} > 3600 and on (host) patroni_primary{job=\"patroni\"} == 1"
        for         = "15m"
        labels      = { severity = "warning" }
        annotations = { summary = "The Postgres leader {{ $labels.host }} archived no WAL for {{ $value | humanizeDuration }} (archive_timeout is ${local.pgs.archive_timeout} s)" }
      },
      {
        alert       = "PostgresBackupFailed"
        expr        = "pgbackrest_backup_last_exit_code{job=\"node\"} != 0"
        for         = "5m"
        labels      = { severity = "warning" }
        annotations = { summary = "The last pgBackRest backup on {{ $labels.host }} failed (exit {{ $value }}): journalctl -u pg-backup" }
      },
      {
        alert       = "PostgresBackupTooOld"
        expr        = "time() - max(pgbackrest_backup_last_success_timestamp_seconds{job=\"node\"}) > 129600 or absent(pgbackrest_backup_last_success_timestamp_seconds{job=\"node\"})"
        for         = "30m"
        labels      = { severity = "warning" }
        annotations = { summary = "No successful pgBackRest backup of ${local.pg_scope} for more than 36 hours" }
      },
      {
        alert       = "EtcdNoLeader"
        expr        = "etcd_server_has_leader{job=\"etcd\"} == 0"
        for         = "1m"
        labels      = { severity = "critical" }
        annotations = { summary = "etcd on {{ $labels.host }} has no leader (Patroni's DCS)" }
      },
      {
        alert       = "EtcdQuorumLost"
        expr        = "count(up{job=\"etcd\"} == 1) < ${floor(length(var.postgres) / 2) + 1} or absent(up{job=\"etcd\"} == 1)"
        for         = "1m"
        labels      = { severity = "critical" }
        annotations = { summary = "Fewer than ${floor(length(var.postgres) / 2) + 1} etcd members are up: no quorum (Patroni can't elect a leader; failsafe_mode keeps a running one)" }
      },
      {
        alert       = "EtcdMembersMissing"
        expr        = "count(up{job=\"etcd\"} == 1) < ${length(var.postgres)}"
        for         = "10m"
        labels      = { severity = "warning" }
        annotations = { summary = "Only {{ $value }} of ${length(var.postgres)} etcd members are up" }
      },
      # etcd sits on Ceph RBD (DT-017): WAL fsync p99 above 100 ms for half an hour means heartbeats are late
      # and elections likely (etcd wants < 10 ms). A member restart also counts as a leader change seen.
      {
        alert       = "EtcdWALFsyncSlow"
        expr        = "histogram_quantile(0.99, sum by (host, le) (rate(etcd_disk_wal_fsync_duration_seconds_bucket{job=\"etcd\"}[10m]))) > 0.1"
        for         = "30m"
        labels      = { severity = "warning" }
        annotations = { summary = "etcd on {{ $labels.host }}: WAL fsync p99 is {{ $value | humanizeDuration }} (over 100 ms for 30m; Patroni's DCS risks elections)" }
      },
      {
        alert       = "EtcdLeaderChanged"
        expr        = "increase(etcd_server_leader_changes_seen_total{job=\"etcd\"}[1h]) > 0"
        labels      = { severity = "warning" }
        annotations = { summary = "etcd on {{ $labels.host }} saw {{ $value | humanize }} leader change(s) in the last hour (slow disk/network, or a member restart)" }
      },
      {
        alert       = "PostgresRGWBackendDown"
        expr        = "haproxy_backend_active_servers{job=\"haproxy-postgres\", proxy=\"rgw\"} == 0"
        for         = "2m"
        labels      = { severity = "critical" }
        annotations = { summary = "haproxy on {{ $labels.host }} has no healthy RGW: pgBackRest can't reach S3" }
      },
      {
        alert       = "PostgresVIPNotHeldOnce"
        expr        = "count(node_network_address_info{job=\"node\", role=\"postgres\", address=\"${local.pg_vip}\"}) != 1 or absent(node_network_address_info{job=\"node\", role=\"postgres\", address=\"${local.pg_vip}\"})"
        for         = "2m"
        labels      = { severity = "critical", vip = local.pg_vip, network = "backend" }
        annotations = { summary = "Postgres VIP ${local.pg_vip} is held by {{ $value }} VMs instead of exactly one" }
      },
    ]
  }] : []
}

# One deploy script per Patroni member. haproxy's port needs an RGW, etcd's health its quorum and Patroni runs
# outside Podman: checked from the host after the restarts (verify). postgres-exporter checks itself (HealthCmd).
module "postgres_deploy" {
  source   = "../quadlet-deploy"
  for_each = local.postgres_enabled ? var.postgres : {}

  name   = "postgres"
  host   = each.key
  images = [var.images.haproxy, var.images.postgres_exporter, var.images.alloy, var.images.node_exporter]
  # pg_textfile: pg-backup writes the backup result there for node_exporter.
  dirs  = concat([{ path = local.pg_textfile, mode = "0755", owner = "0:0" }], local.alloy_dirs)
  files = local.pg_files[each.key]
  checks = concat(
    ["\"$stage/usr/local/sbin/pg-packages\" \"$stage\""], # packages before the checks that need them (pg_packages_script)
    local.pg_version_checks,
    [
      # Schema check. -i: Postgres/REST already listen on later deploys; etcd isn't up yet on the first
      # one, so "is not reachable" (the validator's DCS probe) is the only error tolerated.
      "if command -v patroni >/dev/null; then out=$(patroni --validate-config -i \"$stage/etc/patroni/config.yml\" 2>&1) || if printf '%s\\n' \"$out\" | grep -v 'is not reachable' | grep -q .; then printf '%s\\n' \"$out\" >&2; exit 1; fi; else echo \"patroni not installed yet: config check skipped\"; fi",
      "python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' \"$stage/etc/etcd/etcd.yml\"",
      local.alloy_check[each.key],
      # The snakeoil pair exists once ssl-cert is installed (postgresql-<major> depends on it).
      "if [ -e /etc/ssl/private/ssl-cert-snakeoil.key ]; then podman run --rm --network=none --user 0 -v \"$stage${local.pg_conf}/haproxy:/usr/local/etc/haproxy:ro\" -v /etc/ssl/certs/ssl-cert-snakeoil.pem:/usr/local/etc/haproxy/tls/s3.pem:ro -v /etc/ssl/private/ssl-cert-snakeoil.key:/usr/local/etc/haproxy/tls/s3.pem.key:ro '${var.images.haproxy}' haproxy -c -q -f /usr/local/etc/haproxy/haproxy.cfg; else echo \"no snakeoil certificate yet: haproxy check skipped\"; fi",
      "nft -c -f \"$stage${local.pg_conf}/guard.nft\"",
      local.keepalived_validation,
    ],
  )
  post_install = [
    # The package's default cluster (<major>/main on 5432) and etcd's default single-member
    # data dir exist only after a package install; Patroni and our etcd config use others.
    "if [ -d /etc/postgresql/${local.pg_major}/main ]; then pg_dropcluster --stop ${local.pg_major} main; echo \"dropped the packaged ${local.pg_major}/main cluster\"; fi",
    "if [ -d /var/lib/etcd/default ]; then systemctl stop etcd.service; rm -rf /var/lib/etcd/default; echo \"removed etcd's default data dir\"; fi",
    "systemctl enable --quiet postgres-guard.service etcd.service patroni.service pg-leader-setup.service keepalived.service",
    "systemctl enable --quiet --now pg-backup.timer",
  ]
  units = local.pg_services
  verify = [
    "retry curl -fsSk -o /dev/null --max-time 3 https://127.0.0.1:7443/", # haproxy -> an RGW
    "retry etcdctl --endpoints=http://127.0.0.1:2379 endpoint health",
    # Postgres runs on this member (leader or streaming replica).
    "retry curl -fsS -o /dev/null --max-time 3 http://127.0.0.1:8008/health",
    local.alloy_verify[each.key],
    "retry nft list table inet postgres_guard",
    "retry systemctl is-active --quiet pg-backup.timer",
  ]
}
