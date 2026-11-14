# Stable instance labels for the VM-hosted jobs: instance = "<host>:<port>" instead of "<address>:<port>".
# Scrape addresses move with the network design (mgmt / VLAN 13 -> lylat-telemetry 10.55, later the zones);
# with the address in `instance` every move started a new series. The host label comes from each job's
# static_configs, so a target without one keeps its address. Devices (leaves, switches, PVE exporters, SNMP,
# blackbox, Ceph) keep their own instance handling and are not listed.
locals {
  host_instance_jobs = [
    "prometheus", "alertmanager", "snmp-exporter", "blackbox-exporter", "node", "grafana", "alloy", "loki",
    "mimir", "haproxy", "haproxy-mimir", "haproxy-postgres", "patroni", "etcd", "postgres", "valkey",
    "valkey-sentinel", "nginx", "bind", "netbox",
  ]
  host_instance_relabel = [{
    source_labels = ["host", "__address__"]
    regex         = "(.+);.*:([0-9]+)"
    target_label  = "instance"
    replacement   = "$1:$2"
  }]
  scrape_configs_host_instance = [
    for job in local.scrape_configs : merge(job, {
      for k, v in { relabel_configs = concat(try(job.relabel_configs, []), local.host_instance_relabel) } : k => v
      if contains(local.host_instance_jobs, job.job_name)
    })
  ]
}
