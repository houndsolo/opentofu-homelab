locals {
  # Include both standalone PVE hosts (greatfox) and the PVE cluster.
  # Match the existing management address convention: 10.20.7.<node.id>.
  proxmox_dns_hosts = {
    for name, node in merge(var.nodes.proxmox_cluster, var.nodes.proxmox) :
    name => { A = cidrhost("10.20.7.0/24", node.id) }
  }

  custom_records = concat(flatten([
    for name, records in merge(local.proxmox_dns_hosts, var.dns_hosts) : [
      for type, data in records : {
        name = name
        type = type
        data = data
        ttl  = 300
      }
    ]
  ]), var.dns_records)
}
