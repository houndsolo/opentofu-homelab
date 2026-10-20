locals {
  # Include both standalone PVE hosts (greatfox) and the PVE cluster.
  # Match the existing management address convention: 10.20.7.<node.id>.
  spine_dns_hosts = {
    for name, spine in var.fabric.spines :
    "spine-${spine.id}" => {
      A = split("/", spine.management_ip)[0]
    }
  }

  leaf_dns_hosts = {
    for name, leaf in merge(
      var.fabric.leaves,
      var.nodes.proxmox_cluster,
      var.nodes.proxmox,
    ) :
    "leaf-${leaf.id}" => {
      A = cidrhost(var.fabric.settings.vyos_mgmt_prefix, leaf.id)
    }
  }

  dhcp_dns_hosts = {
    for name, vm in var.vms :
    name => {
      A = split("/", vm.management_address)[0]
    }
    if vm.owner == "services-vms-dhcp"
  }

  proxmox_dns_hosts = {
    for name, node in merge(var.nodes.proxmox_cluster, var.nodes.proxmox) :
    name => { A = cidrhost("10.20.7.0/24", node.id) }
  }

  host_records = flatten([
    for name, records in merge(var.dns_hosts, local.proxmox_dns_hosts,local.spine_dns_hosts, local.leaf_dns_hosts, local.dhcp_dns_hosts)  : [
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
