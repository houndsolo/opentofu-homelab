# Patroni cutover (runbook-postgres.md steps 6 and 8, 2026-11-10): Grafana's database is on the cluster
# VIP (postgres-vip, 10.56.14.104 since the 2026-11-14 zone move), and mon01's Postgres container is removed (its data dir /var/lib/monitoring/postgres
# stays). Rollback: legacy_on_primary = true brings the container back on the old data.
postgres_settings = {
  grafana_on_cluster = true
  legacy_on_primary  = false
}
