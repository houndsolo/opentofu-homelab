locals {
  # Include both standalone PVE hosts (greatfox) and the PVE cluster.
  # Match the existing management address convention: 10.20.7.<node.id>.
  proxmox_vteps = {
    for name, node in merge(var.nodes.proxmox_cluster, var.nodes.proxmox) :
    "leaf-${name}" => { A = cidrhost("10.20.10.0/24", node.id) }
  }

  proxmox_dns_hosts = {
    for name, node in merge(var.nodes.proxmox_cluster, var.nodes.proxmox) :
    name => { A = cidrhost("10.20.7.0/24", node.id) }
  }

  custom_records = concat(flatten([
    for name, records in merge(local.proxmox_dns_hosts, local.proxmox_vteps, var.dns_hosts) : [
      for type, data in records : {
        name = name
        type = type
        data = data
        ttl  = 300
      }
    ]
  ]), var.dns_records)
}

locals {
  # Keep each owner/type RRset together so updates replace all of its values.
  record_sets = {
    for record in local.custom_records :
    "${lower(trimsuffix(record.name, "."))}|${record.type}" => record...
  }
  record_payload = {
    server = local.dns_addresses[var.dns_primary]
    rrsets = [for records in values(local.record_sets) : {
      name = records[0].name == "@" ? "lylat.space." : "${trimsuffix(records[0].name, ".")}.lylat.space."
      type = records[0].type
      ttl  = records[0].ttl
      data = distinct([for record in records : record.data])
    }]
  }
  record_deployment = templatefile("${path.module}/templates/update-records.py.tftpl", {
    payload_b64 = base64encode(jsonencode(local.record_payload))
  })
}
