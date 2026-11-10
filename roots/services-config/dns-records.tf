module "leaves" {
  source = "../../modules/fabric/leaves"
  fabric = var.fabric
  nodes  = var.nodes
}

locals {
  spine_dns_hosts = {
    for name, spine in var.fabric.spines :
    "spine-${spine.id}" => {
      A = split("/", spine.management_ip)[0]
    }
  }

  leaf_dns_hosts = {
    for name, leaf in module.leaves.leaves :
    "leaf-${leaf.id}" => {
      A = cidrhost(var.fabric.settings.management_prefix, leaf.id)
    }
  }

  dhcp_dns_hosts = {
    for name, vm in local.dhcp_vms :
    name => {
      A = split("/", vm.management_address)[0]
    }
  }

  # Cluster and standalone hosts alike.
  proxmox_dns_hosts = {
    for name, node in var.nodes.proxmox :
    name => { A = cidrhost(var.nodes.management_prefix, node.id) }
  }

  host_records = flatten([
    for name, records in merge(local.proxmox_dns_hosts, local.spine_dns_hosts, local.leaf_dns_hosts, local.dhcp_dns_hosts, var.dns_hosts) : [
      for type, data in records : {
        name = name
        type = type
        data = data
        ttl  = 300
      }
    ]
  ])

  custom_records = concat(local.host_records, var.dns_records)
}

locals {
  grouped_records = {
    for record in local.custom_records :
    "${lower(trimsuffix(record.name, "."))}|${record.type}" => record...
  }
  record_sets = {
    for key, records in local.grouped_records : key => {
      name = records[0].name == "@" ? null : lower(trimsuffix(records[0].name, "."))
      type = records[0].type
      # Consistent TTLs are checked by the dns_records input validation.
      ttl  = records[0].ttl
      data = distinct([for record in records : record.data])
    }
  }
}

locals {
  # PTRs in 10.in-addr.arpa for every 10.0.0.0/8 address in the zone (A records + the DNS VMs'
  # own seed records). Several names on one address: the shortest name wins (host over alias).
  ptr_pairs = concat(
    flatten([for key, record in local.record_sets : [
      for ip in record.data : { ip = ip, name = record.name } if startswith(ip, "10.") && record.name != null
    ] if record.type == "A"]),
    [for name, ip in local.dns_addresses : { ip = ip, name = name }],
  )
  ptr_names = { for pair in local.ptr_pairs : pair.ip => format("%03d%s", length(pair.name), pair.name)... }
  ptr_records = {
    for ip, names in local.ptr_names : ip => {
      owner  = join(".", reverse(slice(split(".", ip), 1, 4)))
      target = "${substr(sort(names)[0], 3, -1)}.lylat.space."
    }
  }
}

provider "dns" {
  update {
    server        = local.dns_addresses[var.dns_primary]
    transport     = "tcp"
    key_name      = "tofu-lylat."
    key_algorithm = "hmac-sha256"
    key_secret    = local.dns_tsig_secret
  }
}

# Each block manages one DNS record type. BIND replicates changes to dns02.
resource "dns_a_record_set" "records" {
  for_each  = { for key, record in local.record_sets : key => record if record.type == "A" }
  zone      = "lylat.space."
  name      = each.value.name
  ttl       = each.value.ttl
  addresses = each.value.data

  depends_on = [terraform_data.bind9]
}

resource "dns_aaaa_record_set" "records" {
  for_each  = { for key, record in local.record_sets : key => record if record.type == "AAAA" }
  zone      = "lylat.space."
  name      = each.value.name
  ttl       = each.value.ttl
  addresses = each.value.data

  depends_on = [terraform_data.bind9]
}

resource "dns_cname_record" "records" {
  for_each = { for key, record in local.record_sets : key => record if record.type == "CNAME" }
  zone     = "lylat.space."
  name     = each.value.name
  ttl      = each.value.ttl
  cname    = one(each.value.data)

  depends_on = [terraform_data.bind9]
}

resource "dns_txt_record_set" "records" {
  for_each = { for key, record in local.record_sets : key => record if record.type == "TXT" }
  zone     = "lylat.space."
  name     = each.value.name
  ttl      = each.value.ttl
  txt      = each.value.data

  depends_on = [terraform_data.bind9]
}

resource "dns_ns_record_set" "records" {
  for_each    = { for key, record in local.record_sets : key => record if record.type == "NS" }
  zone        = "lylat.space."
  name        = each.value.name
  ttl         = each.value.ttl
  nameservers = each.value.data

  depends_on = [terraform_data.bind9]
}

resource "dns_ptr_record" "records" {
  for_each = { for key, record in local.record_sets : key => record if record.type == "PTR" }
  zone     = "lylat.space."
  name     = each.value.name
  ttl      = each.value.ttl
  ptr      = one(each.value.data)

  depends_on = [terraform_data.bind9]
}

resource "dns_mx_record_set" "records" {
  for_each = { for key, record in local.record_sets : key => record if record.type == "MX" }
  zone     = "lylat.space."
  name     = each.value.name
  ttl      = each.value.ttl

  dynamic "mx" {
    for_each = each.value.data
    content {
      preference = tonumber(regexall("\\S+", mx.value)[0])
      exchange   = regexall("\\S+", mx.value)[1]
    }
  }

  depends_on = [terraform_data.bind9]
}

resource "dns_srv_record_set" "records" {
  for_each = { for key, record in local.record_sets : key => record if record.type == "SRV" }
  zone     = "lylat.space."
  name     = each.value.name
  ttl      = each.value.ttl

  dynamic "srv" {
    for_each = each.value.data
    content {
      priority = tonumber(regexall("\\S+", srv.value)[0])
      weight   = tonumber(regexall("\\S+", srv.value)[1])
      port     = tonumber(regexall("\\S+", srv.value)[2])
      target   = regexall("\\S+", srv.value)[3]
    }
  }

  depends_on = [terraform_data.bind9]
}

# Reverse zone (served by BIND as 10.in-addr.arpa, dns01 primary -> dns02).
resource "dns_ptr_record" "reverse" {
  for_each = local.ptr_records
  zone     = "10.in-addr.arpa."
  name     = each.value.owner
  ptr      = each.value.target
  ttl      = 300

  depends_on = [terraform_data.bind9]
}
