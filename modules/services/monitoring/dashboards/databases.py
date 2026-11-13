"""The database dashboards (folder Databases): the Patroni cluster, one Postgres member, Valkey.

Built by custom.py (python3 -I modules/services/monitoring/dashboards/custom.py) with its
helpers; see custom.py for the conventions. Started from the community dashboards (grafana.com
25814 "PostgreSQL 18 + Patroni", 18870 "PostgreSQL Patroni", 9628 "PostgreSQL Database", 26033,
22236/3070 etcd, 763 and 9570 Redis/Sentinel), cut down to what this setup has and arranged
around how it's used here:

- Postgres (modules/services/monitoring/postgres.tf): Patroni scope lylat-pg18 on pg01-03, one
  leader holding keepalived's VIP, two async replicas, etcd on the same VMs as the DCS (its data
  dir on Ceph RBD, hence the slow-fsync tuning of DT-017), pgBackRest (WAL archive + daily full
  backup on the leader) to an RGW bucket through a local haproxy. Its users are Grafana (database
  grafana), NetBox (netbox) and dark-triage (triage). Jobs: patroni (:8008), postgres
  (postgres_exporter :9187), etcd (:2381), haproxy-postgres (:8405), node (role postgres; the
  pg-backup textfile metrics pgbackrest_*).
- Valkey (roots/services-config valkey.tf + valkey-monitoring.tf): NetBox's task queue (RQ,
  database 0) and cache (database 1) on valkey01-03, one primary and two replicas, failover by
  three Sentinels (quorum 2). Jobs: valkey (:9121) and valkey-sentinel (:9355), both
  redis_exporter, and node (role valkey).

Patroni, Postgres, pgBackRest and etcd log to the journal, which Alloy ships to Loki (app
"patroni" carries Patroni's, Postgres' and pgBackRest's archive-push lines; app "etcd").
"""
from custom import (
    BLUE, LOGS_DASH, MERGE, NODE_DASH, ORANGE_IF_ANY, PERCENT, UP_MAP, UP_STEPS, Board, bargauge, cell, dashboard,
    fixed_color, gauge, hidden, mapping, organize, override, q, query_var, stat, state_timeline, steps,
    table, timeseries,
)
from logs import logs, lq, on_loki, per_bucket

CLUSTER_DASH = "/d/postgres-cluster/postgres-cluster"
INSTANCE_DASH = "/d/postgres-instance/postgres-instance"
VALKEY_DASH = "/d/valkey/valkey"
TIME = "${__url_time_range}"
DB_LINK = {"type": "dashboards", "tags": ["databases"], "asDropdown": True, "title": "Database dashboards",
           "includeVars": False, "keepTime": True, "icon": "external link", "targetBlank": False,
           "tooltip": "", "url": ""}

OK_FAIL = mapping(**{"0": ("FAIL", "red"), "1": ("OK", "green")})
OK_STEPS = steps(("red", None), ("green", 1))
APPS_DESC = "grafana = Grafana (graf01/02), netbox = NetBox (netbox01/02 web + worker), triage = dark-triage (triage01/02)."

# --- Postgres -----------------------------------------------------------------------------

PAT = 'job="patroni", scope="$scope"'
PG = 'job="postgres"'
ETCD = 'job="etcd"'
PG_NODE = 'job="node", role="postgres"'
LEADER = f"on (host) (patroni_primary{{{PAT}}} == 1)"   # `x and LEADER`: only the leader's series
REPLICA = f"on (host) (patroni_replica{{{PAT}}} == 1)"
USER_DBS = 'datname!~"postgres|template0|template1|"'
VIP = 'job="node", role="postgres", device=~"vrrp.*"'  # keepalived's VIP interface (vrrp.<router id>)
LEADER_XLOG = f"scalar(max(patroni_xlog_location{{{PAT}}} and {LEADER}))"

# patroni_postgres_state (patroni/postgresql/misc.py PostgresqlState: the indexes never change).
PG_STATE_MAP = mapping(**{
    "0": ("initdb", "blue"), "1": ("initdb failed", "red"), "2": ("custom bootstrap", "blue"),
    "3": ("bootstrap failed", "red"), "4": ("creating replica", "blue"), "5": ("running", "green"),
    "6": ("starting", "blue"), "7": ("starting", "blue"), "8": ("start failed", "red"),
    "9": ("restarting", "orange"), "10": ("restart failed", "red"), "11": ("stopping", "orange"),
    "12": ("stopped", "red"), "13": ("stop failed", "red"), "14": ("crashed", "red")})
ROLE_MAP = mapping(**{"2": ("leader", "green"), "1": ("replica", "blue"), "0": ("not running", "red")})
NEED_CHECKPOINTER = "Needs postgres_exporter's stat_checkpointer collector (postgres.tf, not applied yet)"
NEED_POSTMASTER = "Needs postgres_exporter's postmaster collector (postgres.tf, not applied yet)"
NEED_WRAPAROUND = "Needs postgres_exporter's database_wraparound collector (postgres.tf, not applied yet)"
NEED_LONG_TX = "No transaction open longer than a minute (long_running_transactions collector)"

# Patroni's state changes, as Patroni and Postgres log them (switchover, failover, rejoin).
PATRONI_EVENTS = (r"(?i)promot|demot|switchover|failover|following a different leader|starting as a secondary|"
                  r"acquired (the )?leader|lost (the )?leader|released leader|leader key|reinitializ|pg_rewind|"
                  r"bootstrap|paused|resumed|maintenance mode")
PG_ERRORS = r"\b(ERROR|FATAL|PANIC):"
PATRONI_WARN = r",\d{3} (WARNING|ERROR|CRITICAL):"
PGBACKREST_WARN = r"P\d\d +(WARN|ERROR):"


def regex_color(pattern, color):
    return override(f".*{pattern}.*", {"color": {"mode": "fixed", "fixedColor": color}}, regex=True)


def pg_rate(metric, by="datname", sel=PG, window="$__rate_interval"):
    return f"sum by ({by}) (rate({metric}{{{sel}}}[{window}]))"


def on_leader(expr):
    return f"({expr}) and {LEADER}"


def cluster():
    b = Board()
    b.row("Status")
    b.col(4,
          (stat("Leader", [q(f"max by (host) (patroni_primary{{{PAT}}}) == 1", "{{host}}", instant=True)],
                text_mode="name", color_mode="value", thresholds=BLUE, no_value="NO LEADER", text_size=(12, 30),
                desc="The member holding Patroni's leader key: it takes the writes, archives WAL and runs the "
                     "nightly backup. Click for its instance dashboard.",
                links=[("Instance dashboard", INSTANCE_DASH + "?var-host=${__field.labels.host}&" + TIME)]), 4),
          (stat("VIP on", [q(f"max by (host, address) (node_network_address_info{{{VIP}}})", "{{host}}", instant=True)],
                text_mode="name", color_mode="value", thresholds=BLUE, no_value="NOBODY", text_size=(12, 30),
                desc="The member that holds the keepalived VIP (10.13.11.104, what Grafana, NetBox and dark-triage "
                     "connect to). keepalived checks Patroni's /primary, so it must be the leader."), 4))
    checks = [
        ("one leader", f"sum(patroni_primary{{{PAT}}}) == bool 1"),
        ("VIP on leader", f"(count(node_network_address_info{{{VIP}}} and {LEADER}) or vector(0)) == bool 1"),
        ("replicas streaming", f"(count(patroni_replica{{{PAT}}} == 1 and on (host) patroni_postgres_streaming{{{PAT}}} == 1)"
                               f" or vector(0)) >= bool (count(patroni_version{{{PAT}}}) - 1)"),
        ("replicas < 1 MiB behind", f"(max({LEADER_XLOG} - (patroni_xlog_replayed_location{{{PAT}}} and {REPLICA})) or vector(0))"
                                    f" < bool 1048576"),
        ("leader lock held", f"max(patroni_cluster_unlocked{{{PAT}}}) == bool 0"),
        ("auto failover on", f"max(patroni_is_paused{{{PAT}}}) == bool 0"),
        ("etcd quorum", f"(count(etcd_server_has_leader{{{ETCD}}} == 1) or vector(0)) >= bool 2"),
        ("WAL archived < 1 h", f"max(pg_stat_archiver_last_archive_age{{{PG}}} and {LEADER}) < bool 3600"),
        ("backup < 36 h", 'time() - max(pgbackrest_backup_last_success_timestamp_seconds{job="node", stanza="$scope"}) < bool 129600'),
        ("S3 (RGW) reachable", 'min(haproxy_backend_active_servers{job="haproxy-postgres", proxy="rgw"}) > bool 0'),
    ]
    b.add(stat("Checks", [q(e, name, instant=True) for name, e in checks], text_mode="value_and_name",
               mappings=OK_FAIL, thresholds=OK_STEPS, text_size=(11, 14), orientation="horizontal",
               desc="The cluster's invariants, the same ones the postgres alert group watches: one leader with the VIP, "
                    "every replica streaming and within maximum_lag_on_failover (1 MiB, else it can't take over), Patroni "
                    "not paused, etcd quorum (2 of 3), WAL reaching S3 (archive_timeout 300 s), a full backup in the last "
                    "36 h (daily at 01:30) and haproxy seeing at least one RGW."), 8, 8)
    b.col(4,
          (stat("Timeline", [q(f"max(patroni_postgres_timeline{{{PAT}}})", instant=True)], decimals=0, color_mode="value",
                thresholds=BLUE, text_size=(12, 30),
                desc="Postgres' timeline: +1 at every switchover or failover."), 4),
          (stat("Leader changes in range", [
              q(f"max_over_time(max(patroni_postgres_timeline{{{PAT}}})[$__range:1m]) - "
                f"min_over_time(max(patroni_postgres_timeline{{{PAT}}})[$__range:1m])", instant=True)],
              decimals=0, color_mode="value", thresholds=steps(("green", None), ("orange", 1)), text_size=(12, 30),
              desc="Timeline increments in the time range: planned switchovers and failovers alike. See Failover history."), 4))
    b.col(4,
          (stat("Last full backup", [q('time() - max(pgbackrest_backup_last_success_timestamp_seconds{job="node", stanza="$scope"})',
                                       instant=True)],
                unit="dtdurations", color_mode="value", text_size=(12, 22),
                thresholds=steps(("green", None), ("orange", 93600), ("red", 129600)), no_value="never",
                desc="Age of the last successful pgBackRest full backup of this stanza (pg-backup.timer on the leader, "
                     "daily 01:30; alert PostgresBackupTooOld after 36 h)."), 4),
          (stat("Last WAL archived", [q(f"max(pg_stat_archiver_last_archive_age{{{PG}}} and {LEADER})", instant=True)],
                unit="dtdurations", color_mode="value", text_size=(12, 22),
                thresholds=steps(("green", None), ("orange", 900), ("red", 3600)),
                desc="Since the leader last pushed a WAL segment to S3. With writes it's at most archive_timeout "
                     "(300 s); with no writes at all it grows (alert PostgresWALArchiveStale at 1 h)."), 4))
    b.col(4,
          (stat("Connections used", [
              q(f'max(sum by (host) (pg_stat_activity_count{{{PG}}}) / max by (host) (pg_settings_max_connections{{{PG}}}))',
                instant=True)],
              unit="percentunit", decimals=1, color_mode="value", text_size=(12, 22),
              thresholds=steps(("green", None), ("orange", 0.7), ("red", 0.9)),
              desc="The busiest member's backends against max_connections (200)."), 4),
          (stat("Leader WAL rate", [q(f"sum(rate(patroni_xlog_location{{{PAT}}}[5m]) and {LEADER})")],
                unit="Bps", graph=True, color_mode="value", thresholds=BLUE, text_size=(12, 22),
                desc="WAL the leader writes per second: the write load all three apps put on the cluster."), 4))

    b.row("Members")
    member_cols = [
        ("Role", f"max by (host) (patroni_primary{{{PAT}}} * 2 + patroni_replica{{{PAT}}})"),
        ("State", f"max by (host) (patroni_postgres_state{{{PAT}}})"),
        ("Timeline", f"max by (host) (patroni_postgres_timeline{{{PAT}}})"),
        ("Replay lag", f"max by (host) ({LEADER_XLOG} - (patroni_xlog_replayed_location{{{PAT}}} and {REPLICA}))"
                       f" or max by (host) (patroni_primary{{{PAT}}} == 1) * 0"),
        ("Lag (time)", f"max by (host) (pg_replication_lag_seconds{{{PG}}})"),
        ("Streaming", f"max by (host) (patroni_postgres_streaming{{{PAT}}} + 2 * patroni_primary{{{PAT}}})"),
        ("Pending restart", f"max by (host) (patroni_pending_restart{{{PAT}}})"),
        ("DCS seen", f"time() - max by (host) (patroni_dcs_last_seen{{{PAT}}})"),
        ("Postgres up", f"time() - max by (host) (patroni_postmaster_start_time{{{PAT}}})"),
        ("Version", f"max by (host, short_version) (pg_static{{{PG}}})"),
        ("Connections", f"sum by (host) (pg_stat_activity_count{{{PG}}})"),
        ("Slots WAL", f"sum by (host) (pg_replication_slots_pg_wal_lsn_diff{{{PG}}})"),
        ("VIP", f"max by (host) (node_network_address_info{{{VIP}}})"),
    ]
    rename = {"host": "Member", "short_version": "Postgres"}
    rename.update({f"Value #{chr(65 + i)}": name for i, (name, _) in enumerate(member_cols)})
    b.add(table("Members", [q(e, table=True) for _, e in member_cols],
                desc="One row per Patroni member. Replay lag: WAL bytes behind the leader (Patroni's view; over 1 MiB "
                     "it can't be elected). Lag (time): since the last replayed transaction while WAL is pending. "
                     "DCS seen: since the member last refreshed its key in etcd (Patroni's ttl is 30 s). Slots WAL: WAL "
                     "the member keeps for replication slots (Patroni keeps slots for every member, on replicas too). "
                     "Click a member for its instance dashboard.",
                transformations=[MERGE, organize(exclude=["Time", "Value #J"], rename=rename,
                                                 order=["Member", "Role", "State", "VIP", "Timeline", "Streaming",
                                                        "Replay lag", "Lag (time)", "Pending restart", "DCS seen",
                                                        "Postgres up", "Postgres", "Connections", "Slots WAL"])],
                overrides=[
                    override("Role", {"mappings": ROLE_MAP}), cell("Role", "color-background"),
                    override("State", {"mappings": PG_STATE_MAP}), cell("State", "color-text"),
                    override("VIP", {"mappings": mapping(**{"1": ("VIP", "green")})}), cell("VIP", "color-text"),
                    override("Streaming", {"mappings": mapping(**{"0": ("NOT streaming", "red"), "1": ("streaming", "green"),
                                                                  "2": ("(leader)", "text")})}),
                    cell("Streaming", "color-text"),
                    override("Pending restart", {"mappings": mapping(**{"0": ("no", "green"), "1": ("RESTART", "orange")})}),
                    cell("Pending restart", "color-text"),
                    override("Replay lag", {"unit": "bytes", "thresholds": steps(("green", None), ("orange", 65536), ("red", 1048576))}),
                    cell("Replay lag", "color-text"),
                    override("Lag (time)", {"unit": "s", "decimals": 1}),
                    override("DCS seen", {"unit": "s", "decimals": 0, "thresholds": steps(("green", None), ("orange", 20), ("red", 30))}),
                    cell("DCS seen", "color-text"),
                    override("Postgres up", {"unit": "dtdurations"}),
                    override("Slots WAL", {"unit": "bytes"}),
                    override("Connections", {"decimals": 0}),
                    override("Member", {"links": [
                        {"title": "Instance dashboard", "url": INSTANCE_DASH + "?var-host=${__value.raw}&" + TIME},
                        {"title": "Logs of this member", "url": LOGS_DASH + "?var-host=${__value.raw}&" + TIME}]}),
                ], sort="Member"), 24, 6)

    b.row("Failover history")
    b.add(state_timeline("Role", [q(f"max by (host) (patroni_primary{{{PAT}}} * 2 + patroni_replica{{{PAT}}})", "{{host}}")],
                         mappings=ROLE_MAP, thresholds=steps(("red", None), ("blue", 1), ("green", 2)),
                         desc="Who led when. A switchover or failover shows as the green bar moving; gaps are scrapes "
                              "that failed (the member or its Patroni was down)."), 12, 7)
    b.add(logs("Patroni events", f'{{app="patroni"}} != `no action` |~ `{PATRONI_EVENTS}`', max_lines=200,
               desc="Promotions, demotions, switchovers, failovers, rejoin/rewind lines from Patroni and Postgres on all "
                    "members (Loki, app=patroni)."), 12, 7)

    b.row("Replication")
    b.add(timeseries("Replay lag (bytes behind the leader)", [
        q(f"{LEADER_XLOG} - (patroni_xlog_replayed_location{{{PAT}}} and {REPLICA})", "{{host}}")],
        unit="bytes", fill=0, min_=0, desc="Patroni's view, the one failover uses: past maximum_lag_on_failover (1 MiB) "
                                           "a replica can't become leader (alert PatroniReplicaLag)."), 8, 8)
    b.add(timeseries("Replication lag (time)", [q(f"pg_replication_lag_seconds{{{PG}}} and {REPLICA}", "{{host}}")],
                     unit="s", fill=0, min_=0,
                     desc="postgres_exporter: 0 when the replica has replayed everything it received, else the age of "
                          "the last replayed transaction."), 8, 8)
    b.add(timeseries("WAL written / received", [
        q(f"rate(patroni_xlog_location{{{PAT}}}[$__rate_interval]) and {LEADER}", "{{host}} written (leader)"),
        q(f"rate(patroni_xlog_received_location{{{PAT}}}[$__rate_interval]) and {REPLICA}", "{{host}} received"),
    ], unit="Bps", fill=0, desc="WAL the leader generates and each replica receives; the lines should overlap."), 8, 8)
    b.add(table("Streaming replication (leader's pg_stat_replication)", [
        q(f"max by (application_name, client_addr, state, slot_name) (pg_stat_replication_pg_wal_lsn_diff{{{PG}}} and {LEADER})", table=True)],
        desc="The walsenders on the leader: one per replica, state streaming. Lag is the WAL not yet replayed.",
        transformations=[organize(exclude=["Time"], rename={"application_name": "Replica", "client_addr": "From (HA VLAN)",
                                                            "state": "State", "slot_name": "Slot", "Value": "Lag"})],
        overrides=[override("Lag", {"unit": "bytes"}),
                   override("State", {"mappings": mapping(streaming=("streaming", "green"), catchup=("catchup", "orange"),
                                                          backup=("backup", "blue"))}), cell("State", "color-text")],
        no_value="No replica connected to the leader"), 12, 6)
    b.add(timeseries("WAL kept for replication slots", [
        q(f"pg_replication_slots_pg_wal_lsn_diff{{{PG}}}", "{{host}} → {{slot_name}}")], unit="bytes", fill=0, min_=0,
        desc="WAL each member holds back for a slot. A slot whose member is gone keeps growing until the disk "
             "(42 GB root, data dir included) fills: Patroni drops a missing member's slot only once it leaves the cluster."), 12, 6)

    b.row("Apps and connections")
    b.add(stat("Apps", [
        q('max by (host) (probe_success{job="blackbox-http_2xx", host=~"netbox|dark-triage"})', "{{host}} (VIP)", instant=True),
        q('max by (job) (up{job="grafana"})', "grafana", instant=True),
    ], text_mode="value_and_name", mappings=UP_MAP, thresholds=UP_STEPS, orientation="horizontal",
        desc="The apps that use the cluster: NetBox and dark-triage through their HTTP probes on the VIP, Grafana "
             "through its own /metrics (any Grafana up)."), 4, 8)
    b.add(timeseries("Connections per database (all members)", [
        q(f"sum by (datname) (pg_stat_activity_count{{{PG}}})", "{{datname}}")], stack=True, fill=30, decimals=0,
        desc="Backends per database across the members. " + APPS_DESC + " postgres: Patroni, postgres_exporter and "
             "replication.", overrides=[fixed_color("postgres", "text")]), 10, 8)
    b.add(timeseries("Connections by state", [
        q(f'sum by (state) (pg_stat_activity_count{{{PG}}}) > 0', "{{state}}")], stack=True, fill=30, decimals=0,
        desc="'idle in transaction' holds locks and blocks vacuum: an app that leaves transactions open shows here.",
        overrides=[fixed_color("idle in transaction", "orange"), fixed_color("idle in transaction (aborted)", "red"),
                   fixed_color("active", "green"), fixed_color("idle", "blue")]), 10, 8)
    b.add(timeseries("Commits per second (leader)", [
        q(on_leader(pg_rate("pg_stat_database_xact_commit", "host, datname", f'{PG}, {USER_DBS}')), "{{datname}}"),
        q(on_leader(f'sum by (host) (rate(pg_stat_database_xact_rollback{{{PG}, {USER_DBS}}}[$__rate_interval]))'), "rollbacks (all)"),
    ], fill=10, desc="Transactions committed per app database on the leader (only it takes writes; replicas serve no "
                     "reads here). " + APPS_DESC, overrides=[fixed_color("rollbacks (all)", "red")]), 8, 8)
    b.add(timeseries("Rows written per second (leader)", [
        q(on_leader(f"sum by (host, datname) (rate(pg_stat_database_tup_inserted{{{PG}, {USER_DBS}}}[$__rate_interval]) + "
                    f"rate(pg_stat_database_tup_updated{{{PG}, {USER_DBS}}}[$__rate_interval]) + "
                    f"rate(pg_stat_database_tup_deleted{{{PG}, {USER_DBS}}}[$__rate_interval]))"), "{{datname}}")],
        fill=10, desc="Inserted + updated + deleted rows per app database: who drives the WAL volume."), 8, 8)
    b.add(timeseries("Longest open transaction", [
        q(f"max by (datname, state) (pg_stat_activity_max_tx_duration{{{PG}}}) > 0", "{{datname}} ({{state}})")],
        unit="s", fill=0, min_=0, no_value="No open transactions",
        desc="Age of the oldest open transaction per database and state, on any member. Long ones (minutes) hold back "
             "vacuum and replication cleanup."), 8, 8)
    b.add(bargauge("Database size (leader)", [
        q(f"sort_desc(pg_database_size_bytes{{{PG}, {USER_DBS}}} and {LEADER})", "{{datname}}", instant=True)],
        unit="bytes", thresholds=BLUE, mode="gradient", desc=APPS_DESC), 8, 6)
    b.add(timeseries("Database size", [q(f"pg_database_size_bytes{{{PG}, {USER_DBS}}} and {LEADER}", "{{datname}}")],
                     unit="bytes", fill=0, calcs=("min", "max", "lastNotNull"),
                     desc="Per app database on the leader (the replicas are byte-identical)."), 8, 6)
    b.add(timeseries("Growth per day (6 h trend)", [
        q(f"deriv(pg_database_size_bytes{{{PG}, {USER_DBS}}}[6h]) * 86400 and {LEADER}", "{{datname}}")],
        unit="bytes", fill=0, desc="Linear trend of each database's size, as bytes per day."), 8, 6)

    b.row("WAL, archive and backups")
    b.add(table("pgBackRest backups", [
        q('max by (host) (time() - pgbackrest_backup_last_success_timestamp_seconds{job="node", stanza="$scope"})', table=True),
        q('max by (host, type) (pgbackrest_backup_last_exit_code{job="node", stanza="$scope"})', table=True),
        q('max by (host) (pgbackrest_backup_duration_seconds{job="node", stanza="$scope"})', table=True),
        q('max by (host) (time() - pgbackrest_backup_last_run_timestamp_seconds{job="node", stanza="$scope"})', table=True),
    ], desc="pg-backup's result on each member that ran it (node_exporter textfile): the timer fires on all three, only "
            "the leader backs up. A member that led before shows its last run too.",
        transformations=[MERGE, organize(exclude=["Time"], rename={
            "host": "Member", "type": "Type", "Value #A": "Last success", "Value #B": "Last exit code",
            "Value #C": "Duration", "Value #D": "Last run"},
            order=["Member", "Type", "Last success", "Last run", "Last exit code", "Duration"])],
        overrides=[override("Last success", {"unit": "dtdurations"}), override("Last run", {"unit": "dtdurations"}),
                   override("Duration", {"unit": "s"}),
                   override("Last exit code", {"mappings": mapping(**{"0": ("OK", "green")}),
                                               "thresholds": steps(("green", None), ("red", 1))}),
                   cell("Last exit code", "color-background")],
        no_value="No pgBackRest result for this stanza yet"), 8, 6)
    b.add(timeseries("WAL segments archived to S3", [
        q(on_leader(f"sum by (host) (increase(pg_stat_archiver_archived_count{{{PG}}}[1h]))"), "{{host}} per hour"),
        q(f"sum by (host) (increase(pg_stat_archiver_failed_count{{{PG}}}[1h])) > 0", "{{host}} failed per hour"),
    ], decimals=0, fill=10, desc="16 MiB segments pushed by archive_command (pgBackRest). Failures: S3 unreachable "
                                 "(alert PostgresWALArchiveFailing).", overrides=[regex_color("failed", "red")]), 8, 6)
    b.add(timeseries("pg_wal size", [
        q(f"pg_wal_size_bytes{{{PG}}}", "{{host}}"),
        q(f"max(pg_settings_max_wal_size_bytes{{{PG}}})", "max_wal_size"),
    ], unit="bytes", fill=0, min_=0, desc="WAL on disk per member. Above max_wal_size: checkpoints can't recycle it "
                                         "(archiving stuck, or a slot holds it).",
        overrides=[override("max_wal_size", {"custom.lineStyle": {"fill": "dash", "dash": [6, 4]},
                                             "color": {"mode": "fixed", "fixedColor": "orange"}})]), 8, 6)
    b.add(timeseries("Checkpoints", [
        q(f"sum by (host) (increase(pg_stat_checkpointer_num_timed_total{{{PG}}}[1h]))", "{{host}} timed"),
        q(f"sum by (host) (increase(pg_stat_checkpointer_num_requested_total{{{PG}}}[1h]))", "{{host}} requested"),
        q(f"sum by (host) (increase(pg_stat_checkpointer_restartpoints_done_total{{{PG}}}[1h]))", "{{host}} restartpoints"),
    ], decimals=0, fill=0, no_value=NEED_CHECKPOINTER,
        desc="Per hour. Requested checkpoints (WAL reached max_wal_size) instead of timed ones mean max_wal_size is too "
             "small for the write load. Replicas do restartpoints."), 8, 6)
    b.add(timeseries("Checkpoint write / sync time", [
        q(f"rate(pg_stat_checkpointer_write_time_total{{{PG}}}[$__rate_interval]) / 1000", "{{host}} write"),
        q(f"rate(pg_stat_checkpointer_sync_time_total{{{PG}}}[$__rate_interval]) / 1000", "{{host}} sync"),
    ], unit="percentunit", fill=0, no_value=NEED_CHECKPOINTER,
        desc="Share of time spent writing and fsyncing checkpoint buffers. Sync time follows Ceph RBD write latency."), 8, 6)
    b.add(timeseries("RGWs healthy behind haproxy", [
        q('haproxy_backend_active_servers{job="haproxy-postgres", proxy="rgw"}', "{{host}}")], decimals=0, fill=0, min_=0,
        desc="pgBackRest reaches S3 through haproxy on 127.0.0.1:7443; 0 means archiving and backups fail "
             "(alert PostgresRGWBackendDown)."), 8, 6)

    b.row("etcd (Patroni's DCS)")
    b.add(state_timeline("etcd role", [
        q(f"max by (host) (etcd_server_is_leader{{{ETCD}}} + 2 * (1 - etcd_server_has_leader{{{ETCD}}}))", "{{host}}")],
        mappings=mapping(**{"1": ("leader", "green"), "0": ("follower", "blue"), "2": ("NO LEADER", "red")}),
        thresholds=steps(("blue", None), ("green", 1), ("red", 2)),
        desc="Raft leader per member. Without quorum Patroni can't renew the leader key; failsafe_mode keeps the "
             "running leader as long as it can reach both replicas."), 8, 6)
    b.add(timeseries("WAL fsync p99 vs heartbeat", [
        q(f"histogram_quantile(0.99, sum by (le, host) (rate(etcd_disk_wal_fsync_duration_seconds_bucket{{{ETCD}}}[$__rate_interval])))", "{{host}} fsync p99"),
        q(f"histogram_quantile(0.99, sum by (le, host) (rate(etcd_disk_backend_commit_duration_seconds_bucket{{{ETCD}}}[$__rate_interval])))", "{{host}} commit p99"),
        q("vector(0.3)", "heartbeat (300 ms)"),
    ], unit="s", fill=0, min_=0,
        desc="etcd's data dir is on Ceph RBD, whose fsync p99 is 125-355 ms; heartbeat-interval 300 ms and "
             "election-timeout 3 s were raised for it (DT-017). fsyncs regularly above the heartbeat line bring the "
             "hourly re-elections back.",
        overrides=[override("heartbeat (300 ms)", {"custom.lineStyle": {"fill": "dash", "dash": [6, 4]},
                                                   "color": {"mode": "fixed", "fixedColor": "orange"}})]), 8, 6)
    b.add(timeseries("Leader changes and failed proposals", [
        q(f"sum by (host) (increase(etcd_server_leader_changes_seen_total{{{ETCD}}}[1h]))", "{{host}} leader changes"),
        q(f"sum by (host) (increase(etcd_server_proposals_failed_total{{{ETCD}}}[1h]))", "{{host}} failed proposals"),
    ], decimals=0, fill=10, draw="bars", desc="Per hour. Each member counts the same election once."), 8, 6)
    b.add(timeseries("Peer round trip p99", [
        q(f"histogram_quantile(0.99, sum by (le, host, To) (rate(etcd_network_peer_round_trip_time_seconds_bucket{{{ETCD}}}[$__rate_interval])))", "{{host}} → {{To}}")],
        unit="s", fill=0, desc="Between the members over the Postgres HA VLAN."), 8, 6)
    b.add(timeseries("Patroni → etcd: key refreshed", [
        q(f"time() - patroni_dcs_last_seen{{{PAT}}}", "{{host}}"), q("vector(30)", "ttl (30 s)")],
        unit="s", fill=0, min_=0,
        desc="Since each Patroni last wrote its member key (every loop_wait = 10 s). At the ttl a leader that can't "
             "reach etcd loses the lock.",
        overrides=[override("ttl (30 s)", {"custom.lineStyle": {"fill": "dash", "dash": [6, 4]},
                                           "color": {"mode": "fixed", "fixedColor": "red"}})]), 8, 6)
    b.add(timeseries("DB size and proposals", [
        q(f"etcd_mvcc_db_total_size_in_bytes{{{ETCD}}}", "{{host}} db size"),
        q(f"etcd_mvcc_db_total_size_in_use_in_bytes{{{ETCD}}}", "{{host}} in use"),
        q(f"rate(etcd_server_proposals_committed_total{{{ETCD}}}[$__rate_interval])", "{{host}} commits/s"),
    ], fill=0, desc="Patroni's keys are tiny; auto-compaction (1 h) keeps the db small. Commits/s is Patroni's write "
                    "rate (member keys and the leader lock).",
        overrides=[override(".*(size|in use).*", {"unit": "bytes"}, regex=True),
                   override(".*(commits).*", {"custom.axisPlacement": "right", "unit": "ops"}, regex=True)]), 8, 6)

    b.row("Hosts pg01-03")
    b.add(timeseries("CPU", [
        q(f'1 - avg by (host) (rate(node_cpu_seconds_total{{{PG_NODE}, mode="idle"}}[$__rate_interval]))', "{{host}}")],
        unit="percentunit", fill=0, min_=0, max_=1,
        links=[("Node Exporter Full", NODE_DASH + "?var-job=node&" + TIME)]), 6, 6)
    b.add(timeseries("Memory used", [
        q(f"1 - node_memory_MemAvailable_bytes{{{PG_NODE}}} / node_memory_MemTotal_bytes{{{PG_NODE}}}", "{{host}}")],
        unit="percentunit", fill=0, min_=0, max_=1, desc="4 GiB VMs; shared_buffers is part of it, the rest is page cache."), 6, 6)
    b.add(timeseries("Disk busy and latency (vda, Ceph RBD)", [
        q(f'rate(node_disk_io_time_seconds_total{{{PG_NODE}, device="vda"}}[$__rate_interval])', "{{host}} busy"),
        q(f'rate(node_disk_write_time_seconds_total{{{PG_NODE}, device="vda"}}[$__rate_interval]) / '
          f'rate(node_disk_writes_completed_total{{{PG_NODE}, device="vda"}}[$__rate_interval])', "{{host}} write await"),
    ], fill=0, desc="The data dir, pg_wal and etcd all sit on vda (Ceph RBD). Write await is what fsync waits for.",
        overrides=[override(".*(busy).*", {"unit": "percentunit"}, regex=True),
                   override(".*(await).*", {"unit": "s", "custom.axisPlacement": "right"}, regex=True)]), 6, 6)
    b.add(bargauge("Root FS used", [
        q(f'1 - node_filesystem_avail_bytes{{{PG_NODE}, mountpoint="/"}} / node_filesystem_size_bytes{{{PG_NODE}, mountpoint="/"}}',
          "{{host}}", instant=True)], unit="percentunit", min_=0, max_=1, thresholds=PERCENT, mode="gradient",
        desc="Postgres data, pg_wal and etcd live on /."), 6, 6)

    b.row("Logs", collapsed=True)
    b.add(per_bucket("Postgres errors per member", [lq(f'sum by (host) (count_over_time({{app="patroni"}} |~ `{PG_ERRORS}` [$__auto]))', "{{host}}")],
                     desc="ERROR/FATAL/PANIC lines from Postgres (a failed query, a client that went away, ...)."), 8, 7)
    b.add(per_bucket("Patroni warnings and errors per member", [lq(f'sum by (host) (count_over_time({{app="patroni"}} |~ `{PATRONI_WARN}` [$__auto]))', "{{host}}")],
                     desc="Patroni's own WARNING/ERROR lines: mostly etcd timeouts (watchprefix, read timed out)."), 8, 7)
    b.add(per_bucket("etcd warnings per member", [lq('sum by (host) (count_over_time({app="etcd"} |~ `"level":"(warn|error)"` [$__auto]))', "{{host}}")],
                     desc="etcd logs JSON; slow fsyncs and apply requests show up as 'took too long'."), 8, 7)
    b.add(logs("Postgres errors", f'{{app="patroni"}} |~ `{PG_ERRORS}`', max_lines=300), 12, 9)
    b.add(logs("Patroni, pgBackRest and etcd warnings",
               f'{{app=~"patroni|etcd|pg-backup"}} |~ `{PATRONI_WARN}|{PGBACKREST_WARN}|"level":"(warn|error)"`', max_lines=300), 12, 9)

    # The scope that reports now: label_values() over the time range would also offer the previous major's
    # scope (lylat-pg, rebuilt as lylat-pg18 on 2026-11-12) and pick it first.
    scope = query_var("scope", "Cluster", 'query_result(max by (scope) (patroni_version{job="patroni"}))',
                      multi=False, include_all=False)
    scope["regex"] = '/scope="([^"]+)"/'
    return dashboard("postgres-cluster", "Postgres cluster (Patroni)",
                     "The Patroni cluster behind Grafana, NetBox and dark-triage: leader and VIP, health checks, members, "
                     "failovers, replication, the apps' load, WAL archive and backups, etcd and the VMs.",
                     b, tags=["databases", "postgres"], variables=[scope], extra_links=[DB_LINK])


def instance():
    h = 'job="postgres", host="$host"'
    hd = f'{h}, datname=~"$datname"'
    b = Board()
    b.row("$host")
    b.add(stat("Role", [q('max(patroni_primary{job="patroni", host="$host"} * 2 + patroni_replica{job="patroni", host="$host"})',
                          instant=True)], mappings=ROLE_MAP, thresholds=steps(("red", None), ("blue", 1), ("green", 2)),
               links=[("Postgres cluster", CLUSTER_DASH + "?" + TIME)]), 3, 4)
    b.add(stat("Exporter", [q(f"min(pg_up{{{h}}})", instant=True)], mappings=UP_MAP, thresholds=UP_STEPS,
               desc="pg_up: postgres_exporter can log in as pgmon."), 3, 4)
    b.add(stat("Version", [q(f"max by (short_version) (pg_static{{{h}}})", "{{short_version}}", instant=True)],
               text_mode="name", color_mode="value", thresholds=BLUE), 3, 4)
    b.add(stat("Postgres up for", [q('time() - max(patroni_postmaster_start_time{job="patroni", host="$host"})', instant=True)],
               unit="dtdurations", color_mode="value", thresholds=BLUE), 3, 4)
    b.add(gauge("Connections", [q(f"sum(pg_stat_activity_count{{{h}}}) / max(pg_settings_max_connections{{{h}}})", instant=True)],
                unit="percentunit", min_=0, max_=1, thresholds=steps(("green", None), ("orange", 0.7), ("red", 0.9)),
                desc="Backends against max_connections."), 3, 4)
    b.add(stat("Cache hit", [q(f"sum(rate(pg_stat_database_blks_hit{{{hd}}}[$__range])) / "
                               f"(sum(rate(pg_stat_database_blks_hit{{{hd}}}[$__range])) + sum(rate(pg_stat_database_blks_read{{{hd}}}[$__range])))",
                               instant=True)],
               unit="percentunit", decimals=2, color_mode="value", thresholds=steps(("red", None), ("orange", 0.95), ("green", 0.99)),
               desc="Share of block reads served from shared_buffers over the time range (selected databases)."), 3, 4)
    b.add(stat("Commits/s", [q(f"sum(rate(pg_stat_database_xact_commit{{{hd}}}[$__rate_interval]))")], graph=True,
               color_mode="value", thresholds=BLUE, decimals=2), 3, 4)
    b.add(stat("Deadlocks / conflicts", [
        q(f"sum(increase(pg_stat_database_deadlocks{{{hd}}}[$__range])) or vector(0)", "deadlocks", instant=True),
        q(f"sum(increase(pg_stat_database_conflicts{{{hd}}}[$__range])) or vector(0)", "conflicts", instant=True)],
        text_mode="value_and_name", decimals=0, color_mode="value", thresholds=ORANGE_IF_ANY,
        desc="In the time range. Conflicts: queries on a replica cancelled by replay."), 3, 4)

    b.row("Activity")
    b.add(timeseries("Backends by user", [q(f"sum by (usename) (pg_stat_activity_count{{{h}}}) > 0", "{{usename}}")],
                     stack=True, fill=30, decimals=0,
                     desc="postgres: Patroni (heartbeat, REST API); pgmon: postgres_exporter; replicator: walsenders/receivers; "
                          "the rest are the apps' roles."), 8, 8)
    b.add(timeseries("Backends by state", [q(f"sum by (state) (pg_stat_activity_count{{{h}}}) > 0", "{{state}}")],
                     stack=True, fill=30, decimals=0,
                     overrides=[fixed_color("idle in transaction", "orange"), fixed_color("idle in transaction (aborted)", "red"),
                                fixed_color("active", "green"), fixed_color("idle", "blue")]), 8, 8)
    b.add(timeseries("Waiting active backends", [
        q(f'sum by (wait_event_type, wait_event) (pg_stat_activity_count{{{h}, state="active", wait_event_type!=""}}) > 0',
          "{{wait_event_type}}: {{wait_event}}")], stack=True, fill=30, decimals=0, no_value="Nothing waiting",
        desc="Active backends that wait for something: Lock (blocked by another session), IO (disk), LWLock, Client."), 8, 8)
    b.add(timeseries("Transactions per second", [
        q(f"sum by (datname) (rate(pg_stat_database_xact_commit{{{hd}}}[$__rate_interval]))", "{{datname}} commit"),
        q(f"sum by (datname) (rate(pg_stat_database_xact_rollback{{{hd}}}[$__rate_interval])) > 0", "{{datname}} rollback"),
    ], fill=10), 8, 8)
    b.add(timeseries("Rows read per second", [
        q(f"sum by (datname) (rate(pg_stat_database_tup_fetched{{{hd}}}[$__rate_interval]))", "{{datname}} fetched"),
        q(f"sum by (datname) (rate(pg_stat_database_tup_returned{{{hd}}}[$__rate_interval]))", "{{datname}} returned"),
    ], fill=0, desc="Returned much larger than fetched: sequential scans reading rows they then filter out."), 8, 8)
    b.add(timeseries("Rows written per second", [
        q(f"sum by (datname) (rate(pg_stat_database_tup_inserted{{{hd}}}[$__rate_interval]))", "{{datname}} inserted"),
        q(f"sum by (datname) (rate(pg_stat_database_tup_updated{{{hd}}}[$__rate_interval]))", "{{datname}} updated"),
        q(f"sum by (datname) (rate(pg_stat_database_tup_deleted{{{hd}}}[$__rate_interval]))", "{{datname}} deleted"),
    ], fill=0), 8, 8)

    b.row("I/O and memory")
    b.add(timeseries("Cache hit ratio", [
        q(f"sum by (datname) (rate(pg_stat_database_blks_hit{{{hd}}}[$__rate_interval])) / "
          f"(sum by (datname) (rate(pg_stat_database_blks_hit{{{hd}}}[$__rate_interval])) + "
          f"sum by (datname) (rate(pg_stat_database_blks_read{{{hd}}}[$__rate_interval])))", "{{datname}}")],
        unit="percentunit", fill=0, max_=1), 8, 7)
    b.add(timeseries("Blocks read from disk / hit", [
        q(f"sum by (datname) (rate(pg_stat_database_blks_read{{{hd}}}[$__rate_interval])) * 8192", "{{datname}} read"),
        q(f"sum by (datname) (rate(pg_stat_database_blks_hit{{{hd}}}[$__rate_interval])) * 8192", "{{datname}} hit"),
    ], unit="Bps", fill=0, desc="8 KiB blocks: from the OS (page cache or Ceph RBD) vs from shared_buffers."), 8, 7)
    b.add(timeseries("Temp files written", [
        q(f"sum by (datname) (rate(pg_stat_database_temp_bytes{{{hd}}}[$__rate_interval]))", "{{datname}}")],
        unit="Bps", fill=10, no_value="No temp files",
        desc="Sorts and hashes that didn't fit in work_mem spill to disk."), 8, 7)
    b.add(timeseries("Background writer", [
        q(f"rate(pg_stat_bgwriter_buffers_clean_total{{{h}}}[$__rate_interval]) * 8192", "written by bgwriter"),
        q(f"rate(pg_stat_bgwriter_buffers_alloc_total{{{h}}}[$__rate_interval]) * 8192", "allocated"),
        q(f"rate(pg_stat_checkpointer_buffers_written_total{{{h}}}[$__rate_interval]) * 8192", "written by checkpointer"),
    ], unit="Bps", fill=0), 8, 7)
    b.add(timeseries("Checkpoints and restartpoints", [
        q(f"increase(pg_stat_checkpointer_num_timed_total{{{h}}}[1h])", "timed / h"),
        q(f"increase(pg_stat_checkpointer_num_requested_total{{{h}}}[1h])", "requested / h"),
        q(f"increase(pg_stat_checkpointer_restartpoints_done_total{{{h}}}[1h])", "restartpoints / h"),
    ], decimals=0, fill=0, no_value=NEED_CHECKPOINTER), 8, 7)
    b.add(timeseries("pg_wal", [
        q(f"pg_wal_size_bytes{{{h}}}", "size"), q(f"pg_settings_max_wal_size_bytes{{{h}}}", "max_wal_size"),
        q(f"pg_wal_segments{{{h}}}", "segments"),
    ], fill=0, overrides=[override("segments", {"custom.axisPlacement": "right", "decimals": 0}),
                          override(".*(size).*", {"unit": "bytes"}, regex=True)]), 8, 7)

    b.row("Locks, vacuum and wraparound")
    b.add(timeseries("Locks by mode", [q(f"sum by (mode) (pg_locks_count{{{hd}}}) > 0", "{{mode}}")], stack=True,
                     fill=30, decimals=0), 8, 7)
    b.add(timeseries("Longest transaction", [
        q(f"max by (datname, state) (pg_stat_activity_max_tx_duration{{{h}}}) > 0", "{{datname}} ({{state}})"),
        q(f"pg_long_running_transactions_oldest_timestamp_seconds{{{h}}}", "oldest > 1 min"),
    ], unit="s", fill=0, no_value=NEED_LONG_TX), 8, 7)
    b.add(timeseries("Transaction ID age (wraparound)", [
        q(f"pg_database_wraparound_age_datfrozenxid_seconds{{{hd}}}", "{{datname}} xid"),
        q(f"pg_database_wraparound_age_datminmxid_seconds{{{hd}}}", "{{datname}} multixact"),
    ], fill=0, decimals=0, no_value=NEED_WRAPAROUND,
        desc="age(datfrozenxid) per database (the metric says _seconds but it's transactions). Autovacuum freezes at "
             "200 M; trouble starts near 2 billion."), 8, 7)

    b.row("Settings")
    settings = ["max_connections", "shared_buffers_bytes", "effective_cache_size_bytes", "work_mem_bytes",
                "maintenance_work_mem_bytes", "max_wal_size_bytes", "min_wal_size_bytes", "wal_keep_size_bytes",
                "checkpoint_timeout_seconds", "archive_timeout_seconds", "max_replication_slots", "max_wal_senders",
                "hot_standby", "wal_log_hints", "data_checksums", "synchronous_commit", "autovacuum",
                "autovacuum_max_workers", "random_page_cost", "track_io_timing"]
    sel = "|".join(f"pg_settings_{s}" for s in settings)
    b.add(table("Key settings", [
        q(f'label_replace(max by (__name__) ({{__name__=~"{sel}", {h}}}), "setting", "$1", "__name__", "pg_settings_(.*)")',
          table=True)],
        desc="The settings this cluster tunes or depends on (Patroni's bootstrap.dcs and postgresql.parameters). "
             "Sizes in bytes, times in seconds, booleans 1/0. Missing rows: the setting doesn't exist under that name "
             "in this version.",
        transformations=[organize(exclude=["Time", "__name__"], rename={"setting": "Setting", "Value": "Value"})],
        sort="Setting"), 12, 9)
    b.add(table("Settings that differ between members", [
        q(f'count by (setting) (count_values by (setting) ("v", label_replace({{__name__=~"pg_settings_.+", {PG}}}, '
          f'"setting", "$1", "__name__", "pg_settings_(.*)"))) > 1', table=True)],
        desc="Settings whose value isn't the same on all members (count of distinct values > 1). Normally empty: "
             "Patroni applies the same parameters everywhere; a difference means a pending restart or a hand edit. "
             "patroni_pending_restart says which member still runs the old value.",
        transformations=[organize(exclude=["Time"], rename={"setting": "Setting", "Value": "Distinct values"})],
        no_value="All members run the same settings"), 12, 9)

    b.row("postgres_exporter", collapsed=True)
    b.add(state_timeline("Collectors", [q(f"pg_scrape_collector_success{{{h}}}", "{{collector}}")],
                         mappings=OK_FAIL, thresholds=OK_STEPS, row_height=0.8), 12, 8)
    b.add(timeseries("Collector duration", [q(f"pg_scrape_collector_duration_seconds{{{h}}}", "{{collector}}")],
                     unit="s", fill=0, placement="right"), 12, 8)

    host = query_var("host", "Member", 'label_values(pg_up{job="postgres"}, host)', multi=False, include_all=False)
    dbs = query_var("datname", "Database", 'label_values(pg_stat_database_numbackends{job="postgres", host="$host"}, datname)')
    return dashboard("postgres-instance", "Postgres instance",
                     "One member of the Patroni cluster from postgres_exporter: activity, throughput, I/O, checkpoints, "
                     "locks, wraparound and settings. Database picker for the per-database panels.",
                     b, tags=["databases", "postgres"], variables=[host, dbs], extra_links=[DB_LINK])



# --- Valkey ---------------------------------------------------------------------------------

VK = 'job="valkey"'
SN = 'job="valkey-sentinel"'
VK_NODE = 'job="node", role="valkey"'
PRIMARY = f'on (host) (redis_instance_info{{{VK}, role="master"}})'
NO_VALKEY = "No data from the valkey job (redis_exporter, services-config valkey-monitoring.tf) yet"
NEED_KEYS = ("Needs redis_exporter --check-keys for NetBox's RQ keys "
             "(REDIS_EXPORTER_CHECK_KEYS=db0=rq:queue:*,db0=rq:failed:*,db0=rq:workers)")
# RQ deletes a queue's list when it's empty, so "no rq:queue:* key" with rq:workers present means 0 queued.
RQ_QUEUED = f'sum(redis_key_size{{{VK}, db="db0", key=~"rq:queue:.*"}} and {PRIMARY})'
RQ_ZERO = f'max(redis_key_size{{{VK}, db="db0", key="rq:workers"}} and {PRIMARY}) * 0'
# What redis_exporter itself sends on every scrape; left out of the command panels.
APP_CMDS = 'cmd!~"info|latency.*|config.*|auth|ping|slowlog.*|client.*|select|dbsize|memory.*|cluster.*|hello|command.*"'
SENTINEL_EVENTS = r"[+-](switch-master|sdown|odown|failover|try-failover|elected-leader|selected-slave|promoted-slave|slave-reconf|convert-to-slave|tilt|reboot)"


def valkey():
    b = Board()
    b.row("Status")
    b.col(4,
          (stat("Primary", [q(f'max by (host) (redis_instance_info{{{VK}, role="master"}})', "{{host}}", instant=True)],
                text_mode="name", color_mode="value", thresholds=BLUE, no_value="NO PRIMARY", text_size=(12, 30),
                desc="The Valkey that takes writes. NetBox finds it by asking the Sentinels (REDIS_SENTINELS)."), 4),
          (stat("Sentinels say", [q(f"max by (master_address) (redis_sentinel_master_status{{{SN}}})", "{{master_address}}",
                                    instant=True)],
                text_mode="name", color_mode="value", thresholds=BLUE, no_value="no Sentinel data", text_size=(12, 22),
                desc="The primary address each Sentinel reports; more than one name here means they disagree."), 4))
    checks = [
        ("one primary", f'count(redis_instance_info{{{VK}, role="master"}}) == bool 1'),
        ("replicas linked", f"(count(redis_master_link_up{{{VK}}} == 1) or vector(0)) >= bool (count(redis_up{{{VK}}}) - 1)"),
        ("Sentinels agree", f"count(count by (master_address) (redis_sentinel_master_status{{{SN}}})) == bool 1"),
        ("Sentinel quorum", f"min(redis_sentinel_master_ckquorum_status{{{SN}}}) == bool 1"),
        ("all Sentinels seen", f"min(redis_sentinel_master_ok_sentinels{{{SN}}}) >= bool count(redis_up{{{SN}}})"),
        ("memory < 80 %", f"max(redis_memory_used_bytes{{{VK}}} / redis_memory_max_bytes{{{VK}}}) < bool 0.8"),
        ("AOF/RDB writes ok", f"min(redis_aof_last_write_status{{{VK}}} * redis_rdb_last_bgsave_status{{{VK}}}) == bool 1"),
        ("exporters up", f"min(redis_up{{{VK}}}) * min(redis_up{{{SN}}})"),
    ]
    b.add(stat("Checks", [q(e, name, instant=True) for name, e in checks], text_mode="value_and_name",
               mappings=OK_FAIL, thresholds=OK_STEPS, text_size=(11, 14), orientation="horizontal", no_value=NO_VALKEY,
               desc="One primary with both replicas linked, the three Sentinels agreeing on it with quorum (2), memory "
                    "under 80 % of maxmemory (512 MB, policy noeviction: at 100 % writes fail and NetBox's jobs stop), "
                    "persistence (appendonly) working."), 8, 8)
    b.col(4,
          (stat("Failovers in range", [q(f"max(max_over_time(redis_sentinel_master_config_epoch{{{SN}}}[$__range])) - "
                                         f"min(min_over_time(redis_sentinel_master_config_epoch{{{SN}}}[$__range]))", instant=True)],
                decimals=0, color_mode="value", thresholds=steps(("green", None), ("orange", 1)), text_size=(12, 30),
                desc="Sentinel's config epoch rises by one per failover."), 4),
          (gauge("Memory (primary)", [q(f"max(redis_memory_used_bytes{{{VK}}} / redis_memory_max_bytes{{{VK}}} and {PRIMARY})",
                                        instant=True)],
                 unit="percentunit", min_=0, max_=1, thresholds=steps(("green", None), ("orange", 0.8), ("red", 0.95)),
                 desc="used_memory against maxmemory (512 MB)."), 4))
    b.col(4,
          (stat("NetBox clients", [
              q(f"max(redis_connected_clients{{{VK}}} and {PRIMARY})", "connected", instant=True),
              q(f"max(redis_blocked_clients{{{VK}}} and {PRIMARY})", "blocked (idle workers)", instant=True)],
              text_mode="value_and_name", color_mode="value", thresholds=BLUE, decimals=0, text_size=(11, 20),
              desc="Clients of the primary (NetBox web and worker on netbox01/02, the replicas, the exporter). RQ "
                   "workers wait for jobs in a blocking pop, so 'blocked' is the number of idle workers."), 4),
          (stat("Ops/s (primary)", [q(f"sum(rate(redis_commands_processed_total{{{VK}}}[$__rate_interval]) and {PRIMARY})")],
                graph=True, color_mode="value", thresholds=BLUE, decimals=1, text_size=(12, 20)), 4))
    b.col(4,
          (stat("Keys", [q(f'max by (db) (redis_db_keys{{{VK}}} and {PRIMARY})', "{{db}}", instant=True)],
                text_mode="value_and_name", color_mode="value", thresholds=BLUE, decimals=0, text_size=(11, 20),
                desc="db0: NetBox's task queue (RQ jobs, workers, registries); db1: its cache."), 4),
          (stat("RQ jobs queued", [q(f"{RQ_QUEUED} or {RQ_ZERO}", instant=True)],
                decimals=0, color_mode="value", thresholds=steps(("green", None), ("orange", 10), ("red", 100)),
                text_size=(12, 30), no_value=NEED_KEYS,
                desc="Jobs waiting in NetBox's RQ queues (high, default, low). A growing number means netbox-worker "
                     "is down or stuck."), 4))

    b.row("Nodes")
    cols = [
        ("Role", f'max by (host) (redis_instance_info{{{VK}, role="master"}}) * 2 or max by (host) (redis_instance_info{{{VK}, role="slave"}})'),
        ("Up", f"max by (host) (redis_up{{{VK}}})"),
        ("Version", f"max by (host, valkey_version) (redis_instance_info{{{VK}}})"),
        ("Link", f"max by (host) (redis_master_link_up{{{VK}}})"),
        ("Behind", f"max by (host) (scalar(max(redis_master_repl_offset{{{VK}}} and {PRIMARY})) - redis_slave_repl_offset{{{VK}}})"),
        ("Memory", f"max by (host) (redis_memory_used_bytes{{{VK}}})"),
        ("Clients", f"max by (host) (redis_connected_clients{{{VK}}})"),
        ("Keys", f"sum by (host) (redis_db_keys{{{VK}}})"),
        ("AOF", f"max by (host) (redis_aof_last_write_status{{{VK}}})"),
        ("Uptime", f"max by (host) (redis_uptime_in_seconds{{{VK}}})"),
        ("Sentinel", f"max by (host) (redis_up{{{SN}}})"),
    ]
    rename = {"host": "Node", "valkey_version": "Valkey"}
    rename.update({f"Value #{chr(65 + i)}": name for i, (name, _) in enumerate(cols)})
    b.add(table("Nodes", [q(e, table=True) for _, e in cols],
                desc="Behind: replication offset bytes the replica hasn't received yet. Link: the replica's link to the "
                     "primary (empty on the primary). Sentinel: that VM's Sentinel answers its exporter.",
                transformations=[MERGE, organize(exclude=["Time", "Value #C"], rename=rename,
                                                 order=["Node", "Role", "Up", "Link", "Behind", "Sentinel", "Memory",
                                                        "Clients", "Keys", "AOF", "Uptime", "Valkey"])],
                overrides=[override("Role", {"mappings": mapping(**{"2": ("primary", "green"), "1": ("replica", "blue")})}),
                           cell("Role", "color-background"),
                           override("Up", {"mappings": UP_MAP}), cell("Up", "color-text"),
                           override("Sentinel", {"mappings": UP_MAP}), cell("Sentinel", "color-text"),
                           override("Link", {"mappings": mapping(**{"0": ("DOWN", "red"), "1": ("up", "green")})}),
                           cell("Link", "color-text"),
                           override("AOF", {"mappings": OK_FAIL}), cell("AOF", "color-text"),
                           override("Behind", {"unit": "bytes"}), override("Memory", {"unit": "bytes"}),
                           override("Uptime", {"unit": "dtdurations"}),
                           override("Node", {"links": [{"title": "Logs of this node",
                                                        "url": LOGS_DASH + "?var-host=${__value.raw}&" + TIME}]})],
                no_value=NO_VALKEY, sort="Node"), 24, 5)

    b.row("Failover history")
    b.add(state_timeline("Role", [
        q(f'max by (host) (redis_instance_info{{{VK}, role="master"}}) * 2 or max by (host) (redis_instance_info{{{VK}, role="slave"}}) '
          f'or max by (host) (redis_up{{{VK}}} == 0)', "{{host}}")],
        mappings=mapping(**{"2": ("primary", "green"), "1": ("replica", "blue"), "0": ("down", "red")}),
        thresholds=steps(("red", None), ("blue", 1), ("green", 2)), no_value=NO_VALKEY), 12, 6)
    b.add(on_loki(logs("Sentinel events", f'{{host=~"valkey.*"}} |~ `{SENTINEL_EVENTS}`', max_lines=200,
                       desc="+sdown/+odown (a node unreachable), +try-failover/+elected-leader/+promoted-slave (a "
                            "failover) and +switch-master (the new primary) from the Sentinels' logs.")), 12, 6)

    b.row("Replication and Sentinels")
    b.add(timeseries("Replica lag", [
        q(f"redis_connected_slave_lag_seconds{{{VK}}}", "{{slave_ip}} (seconds since ack)"),
        q(f"scalar(max(redis_master_repl_offset{{{VK}}} and {PRIMARY})) - redis_slave_repl_offset{{{VK}}}", "{{host}} bytes behind"),
    ], fill=0, min_=0, no_value=NO_VALKEY,
        overrides=[override(".*(bytes).*", {"unit": "bytes", "custom.axisPlacement": "right"}, regex=True),
                   override(".*(seconds).*", {"unit": "s"}, regex=True)]), 8, 7)
    b.add(timeseries("What each Sentinel sees", [
        q(f"redis_sentinel_master_ok_sentinels{{{SN}}}", "{{host}} Sentinels"),
        q(f"redis_sentinel_master_ok_slaves{{{SN}}}", "{{host}} replicas"),
    ], decimals=0, fill=0, min_=0, no_value="No data from the valkey-sentinel job yet",
        desc="Healthy: every Sentinel sees 3 Sentinels (itself included) and 2 replicas."), 8, 7)
    b.add(timeseries("Full and partial resyncs", [
        q(f"increase(redis_replica_resyncs_full{{{VK}}}[1h])", "{{host}} full"),
        q(f"increase(redis_replica_partial_resync_accepted{{{VK}}}[1h])", "{{host}} partial"),
    ], decimals=0, fill=10, draw="bars", no_value=NO_VALKEY,
        desc="Per hour, counted on the primary. A full resync copies the whole dataset (after a failover or a long "
             "outage); partial ones only the backlog."), 8, 7)

    b.row("Load")
    b.add(timeseries("Commands per second (primary)", [
        q(f'topk(10, sum by (cmd) (rate(redis_commands_total{{{VK}, {APP_CMDS}}}[$__rate_interval]) and {PRIMARY}))', "{{cmd}}")],
        fill=10, stack=True, placement="right", no_value="No commands from NetBox in range",
        desc="NetBox's commands (the exporters' own INFO/CONFIG/LATENCY/AUTH... left out): RQ uses lists, sorted "
             "sets and hashes (lpush, blmove, zadd, hset, exec...), the cache get/set."), 12, 7)
    b.add(timeseries("Latency p99 per command (primary)", [
        q(f"topk(10, histogram_quantile(0.99, sum by (le, cmd) (rate(redis_commands_latencies_usec_bucket{{{VK}, {APP_CMDS}}}"
          f"[$__rate_interval]) and {PRIMARY})))", "{{cmd}}")],
        unit="µs", fill=0, placement="right", no_value="No commands from NetBox in range",
        desc="From Valkey's per-command latency histograms (LATENCY HISTOGRAM): time inside Valkey, not the network."), 12, 7)
    b.add(timeseries("Cache hit ratio", [
        q(f"sum by (host) (rate(redis_keyspace_hits_total{{{VK}}}[$__rate_interval])) / "
          f"(sum by (host) (rate(redis_keyspace_hits_total{{{VK}}}[$__rate_interval])) + "
          f"sum by (host) (rate(redis_keyspace_misses_total{{{VK}}}[$__rate_interval])))", "{{host}}")],
        unit="percentunit", fill=0, max_=1, no_value=NO_VALKEY,
        desc="Lookups that found their key: NetBox's cache (db1) and RQ's polling (db0) together."), 8, 7)
    b.add(timeseries("Network", [
        q(f"rate(redis_net_input_bytes_total{{{VK}}}[$__rate_interval])", "{{host}} in"),
        q(f"-rate(redis_net_output_bytes_total{{{VK}}}[$__rate_interval])", "{{host}} out"),
    ], unit="Bps", fill=10, no_value=NO_VALKEY), 8, 7)
    b.add(timeseries("Connections and errors", [
        q(f"rate(redis_connections_received_total{{{VK}}}[$__rate_interval]) * 60", "{{host}} new / min"),
        q(f"rate(redis_rejected_connections_total{{{VK}}}[$__rate_interval]) * 60 > 0", "{{host}} rejected / min"),
        q(f"sum by (host, err) (rate(redis_errors_total{{{VK}}}[$__rate_interval])) * 60 > 0", "{{host}} {{err}} / min"),
    ], fill=0, no_value=NO_VALKEY,
        desc="Error replies by type (errorstats): NOAUTH/WRONGPASS mean a client with the wrong password."), 8, 7)

    b.row("NetBox task queue (RQ, db0)")
    b.add(timeseries("Jobs queued", [q(f'max by (key) (redis_key_size{{{VK}, db="db0", key=~"rq:queue:.*"}} and {PRIMARY})', "{{key}}"),
                                     q(f"{RQ_QUEUED} or {RQ_ZERO}", "all queues")],
                     decimals=0, fill=10, stack=True, no_value=NEED_KEYS,
                     desc="Waiting jobs per queue (NetBox: high, default, low)."), 8, 6)
    b.add(timeseries("Failed jobs", [q(f'max by (key) (redis_key_size{{{VK}, db="db0", key=~"rq:failed:.*"}} and {PRIMARY})', "{{key}}")],
                     decimals=0, fill=10, no_value=NEED_KEYS,
                     desc="RQ's failed job registry per queue (kept for result_ttl). NetBox shows them under Admin > "
                          "Background Tasks."), 8, 6)
    b.add(timeseries("Workers", [
        q(f'max(redis_key_size{{{VK}, db="db0", key="rq:workers"}} and {PRIMARY})', "registered"),
        q(f"max(redis_blocked_clients{{{VK}}} and {PRIMARY})", "idle (blocked pop)"),
    ], decimals=0, fill=0, desc="netbox-worker processes registered with RQ (one per NetBox VM) and how many wait for work."), 8, 6)

    b.row("Memory and persistence")
    b.add(timeseries("Memory", [
        q(f"redis_memory_used_bytes{{{VK}}}", "{{host}} used"),
        q(f"redis_memory_used_rss_bytes{{{VK}}}", "{{host}} RSS"),
        q(f"max(redis_memory_max_bytes{{{VK}}})", "maxmemory"),
    ], unit="bytes", fill=0, min_=0, no_value=NO_VALKEY,
        overrides=[override("maxmemory", {"custom.lineStyle": {"fill": "dash", "dash": [6, 4]},
                                          "color": {"mode": "fixed", "fixedColor": "red"}})]), 8, 7)
    b.add(timeseries("Keys per database", [q(f"redis_db_keys{{{VK}}}", "{{host}} {{db}}"),
                                           q(f"redis_db_keys_expiring{{{VK}}}", "{{host}} {{db}} expiring")],
                     decimals=0, fill=0, no_value=NO_VALKEY), 8, 7)
    b.add(timeseries("Expired / evicted keys", [
        q(f"rate(redis_expired_keys_total{{{VK}}}[$__rate_interval]) * 60", "{{host}} expired / min"),
        q(f"rate(redis_evicted_keys_total{{{VK}}}[$__rate_interval]) * 60", "{{host}} evicted / min"),
    ], fill=0, no_value=NO_VALKEY, desc="Eviction stays 0 with maxmemory-policy noeviction; writes fail instead.",
        overrides=[regex_color("evicted", "red")]), 8, 7)
    b.add(timeseries("AOF", [
        q(f"redis_aof_current_size_bytes{{{VK}}}", "{{host}} size"),
        q(f"redis_aof_rewrite_in_progress{{{VK}}}", "{{host}} rewriting"),
    ], fill=0, no_value=NO_VALKEY, desc="appendonly yes: the task queue survives a restart. The AOF is rewritten "
                                        "(compacted) when it doubles.",
        overrides=[override(".*(size).*", {"unit": "bytes"}, regex=True),
                   override(".*(rewriting).*", {"custom.axisPlacement": "right", "decimals": 0}, regex=True)]), 8, 7)
    b.add(timeseries("Fragmentation", [q(f"redis_mem_fragmentation_ratio{{{VK}}}", "{{host}}")], fill=0,
                     no_value=NO_VALKEY, desc="RSS / used. High values on a small dataset are normal (allocator overhead)."), 8, 7)
    b.add(timeseries("Since last RDB save", [
        q(f"time() - redis_rdb_last_save_timestamp_seconds{{{VK}}}", "{{host}}")], unit="s", fill=0, no_value=NO_VALKEY,
        desc="Valkey also snapshots on its default save rules; replicas get one per full resync."), 8, 7)

    b.row("Hosts valkey01-03")
    b.add(timeseries("CPU", [
        q(f'1 - avg by (host) (rate(node_cpu_seconds_total{{{VK_NODE}, mode="idle"}}[$__rate_interval]))', "{{host}}")],
        unit="percentunit", fill=0, min_=0, max_=1, no_value="No node_exporter on the Valkey VMs yet",
        links=[("Node Exporter Full", NODE_DASH + "?var-job=node&" + TIME)]), 8, 6)
    b.add(timeseries("Memory used", [
        q(f"1 - node_memory_MemAvailable_bytes{{{VK_NODE}}} / node_memory_MemTotal_bytes{{{VK_NODE}}}", "{{host}}")],
        unit="percentunit", fill=0, min_=0, max_=1, no_value="No node_exporter on the Valkey VMs yet"), 8, 6)
    b.add(bargauge("Root FS used", [
        q(f'1 - node_filesystem_avail_bytes{{{VK_NODE}, mountpoint="/"}} / node_filesystem_size_bytes{{{VK_NODE}, mountpoint="/"}}',
          "{{host}}", instant=True)], unit="percentunit", min_=0, max_=1, thresholds=PERCENT, mode="gradient",
        no_value="No node_exporter on the Valkey VMs yet", desc="The AOF and RDB live in /var/lib/valkey."), 8, 6)

    b.row("Logs", collapsed=True)
    b.add(logs("Valkey and Sentinel log", '{host=~"valkey.*", app=~"valkey.*|redis.*"}', max_lines=300,
               desc="valkey-server and valkey-sentinel from the journal (Alloy to Loki)."), 24, 10)

    return dashboard("valkey", "Valkey (NetBox cache and queue)",
                     "The Valkey trio behind NetBox: primary and Sentinel agreement, replication, load, NetBox's RQ task "
                     "queue, memory and persistence.",
                     b, tags=["databases", "valkey"], extra_links=[DB_LINK])


def overview_row(b):
    """Postgres and Valkey at a glance for custom.overview(): one line of tiles linking to their dashboards."""
    pg = 'job="patroni"'
    pg_link = [("Postgres cluster (Patroni)", CLUSTER_DASH + "?" + TIME)]
    vk_link = [("Valkey", VALKEY_DASH + "?" + TIME)]
    leader = f"on (host) (patroni_primary{{{pg}}} == 1)"
    b.add(stat("Postgres leader", [q(f"max by (host) (patroni_primary{{{pg}}}) == 1", "{{host}}", instant=True)],
               text_mode="name", color_mode="value", thresholds=BLUE, no_value="NO LEADER", text_size=(12, 26),
               links=pg_link, desc="Patroni's leader (takes the writes and holds postgres-vip). Grafana, NetBox and "
                                   "dark-triage keep their data here."), 4, 5)
    b.add(stat("Postgres members", [
        q(f"count(patroni_replica{{{pg}}} == 1 and on (host) patroni_postgres_streaming{{{pg}}} == 1) or vector(0)",
          "replicas streaming", instant=True),
        q(f"max(patroni_xlog_location{{{pg}}}) - min(patroni_xlog_replayed_location{{{pg}}} and on (host) "
          f"patroni_replica{{{pg}}} == 1)", "max lag", instant=True),
    ], text_mode="value_and_name", color_mode="value", thresholds=BLUE, text_size=(11, 18), links=pg_link,
        overrides=[override("max lag", {"unit": "bytes", "thresholds": steps(("green", None), ("orange", 1048576))}),
                   override("replicas streaming", {"thresholds": steps(("red", None), ("orange", 1), ("green", 2))})],
        desc="Replicas streaming from the leader (2 of 2 expected) and the largest replay lag. Over 1 MiB a replica "
             "can't take over (maximum_lag_on_failover)."), 5, 5)
    b.add(stat("Postgres transactions/s", [
        q('sum(rate(pg_stat_database_xact_commit{job="postgres"}[$__rate_interval]) and ' + leader + ')',
          "commits")], decimals=1, graph=True, color_mode="value", thresholds=BLUE, links=pg_link,
        desc="Commits per second on the leader, all databases."), 4, 5)
    b.add(stat("Valkey primary", [q(f'max by (host) (redis_instance_info{{{VK}, role="master"}})', "{{host}}",
                                    instant=True)],
               text_mode="name", color_mode="value", thresholds=BLUE, no_value="NO PRIMARY", text_size=(12, 26),
               links=vk_link, desc="NetBox's task queue and cache; Sentinel picks the primary."), 4, 5)
    b.add(gauge("Valkey memory", [q(f"max(redis_memory_used_bytes{{{VK}}} / redis_memory_max_bytes{{{VK}}} and {PRIMARY})",
                                    instant=True)],
                unit="percentunit", min_=0, max_=1, thresholds=steps(("green", None), ("orange", 0.8), ("red", 0.95)),
                links=vk_link, desc="used_memory / maxmemory (noeviction: at 100 % NetBox's writes fail)."), 3, 5)
    b.add(stat("NetBox jobs queued", [q(f"{RQ_QUEUED} or {RQ_ZERO}", instant=True)], decimals=0, color_mode="value",
               thresholds=steps(("green", None), ("orange", 10), ("red", 100)), links=vk_link, text_size=(12, 26),
               desc="RQ jobs waiting in Valkey. Growing = netbox-worker down or stuck."), 4, 5)


DASHBOARDS = {
    "Databases/postgres-cluster.json": cluster,
    "Databases/postgres-instance.json": instance,
    "Databases/valkey.json": valkey,
}
