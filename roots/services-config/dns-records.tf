module "leaves" {
  source = "../../modules/fabric/leaves"
  fabric = var.fabric
  nodes  = var.nodes
}

# Generated records (2026-11-12): names come from the inventory instead of dns-records.auto.tfvars.
#   <vm>            the VM's service address: the NIC with the default gateway (VLAN 2 for most
#                   service VMs), or its management address if it has none (dhcp01/02)
#   <vm>.mgmt       the VM's management address (10.20.x.x)
#   <vip>           every keepalived VIP in inventory/auto.tfvars/vips.auto.tfvars
#   <node>, <node>.mgmt, leaf-<id>(.mgmt), spine-<id>(.mgmt)   Proxmox hosts and the fabric
# Everything with a management address is also under mgmt.lylat.space, so "search mgmt.lylat.space"
# on an admin box makes plain names reach the management network. dns-records.auto.tfvars keeps only
# what the inventory doesn't know (aliases, outside hosts, MX/TXT/SRV); a name there that is also
# generated fails the check below. The DNS VMs' own <vm> records come from the zone template.
locals {
  spine_dns_hosts = merge([
    for name, spine in var.fabric.spines : {
      "spine-${spine.id}"      = { A = split("/", spine.management_ip)[0] }
      "spine-${spine.id}.mgmt" = { A = split("/", spine.management_ip)[0] }
    }
  ]...)

  leaf_dns_hosts = merge([
    for name, leaf in module.leaves.leaves : {
      "leaf-${leaf.id}"      = { A = cidrhost(var.fabric.settings.management_prefix, leaf.id) }
      "leaf-${leaf.id}.mgmt" = { A = cidrhost(var.fabric.settings.management_prefix, leaf.id) }
    }
  ]...)

  # Cluster and standalone hosts alike.
  proxmox_dns_hosts = merge([
    for name, node in var.nodes.proxmox : {
      (name)         = { A = cidrhost(var.nodes.management_prefix, node.id) }
      "${name}.mgmt" = { A = cidrhost(var.nodes.management_prefix, node.id) }
    }
  ]...)

  # Service and workload VMs (the fabric VMs are the leaves above).
  vm_service_address = {
    for name, vm in var.vms : name => try(split("/", one([
      for nic in vm.network_devices : nic.ipv4_address if nic.ipv4_address != null && nic.ipv4_gateway != null
    ]))[0], null)
    if vm.owner != "fabric-vms"
  }
  vm_dns_hosts = merge([
    for name, vm in var.vms : merge(
      vm.management_address == "dhcp" ? {} : { "${name}.mgmt" = { A = split("/", vm.management_address)[0] } },
      contains(keys(local.dns_vms), name) ? {} : (
        local.vm_service_address[name] != null ? { (name) = { A = local.vm_service_address[name] } } : (
          vm.management_address == "dhcp" ? {} : { (name) = { A = split("/", vm.management_address)[0] } }
        )
      ),
    ) if vm.owner != "fabric-vms"
  ]...)

  vip_dns_hosts = { for name, vip in var.vips : name => { A = split("/", vip.address)[0] } }

  # Web UIs behind the reverse proxy (proxy.tf): every published name and alias is a CNAME to the
  # proxy VIP's name (the vips.auto.tfvars key with role "proxy", proxy-vip). Their services' own VIPs
  # are separate records (<name>-vip above).
  proxy_vip_name = try(one([for name, vip in var.vips : name if vip.role == "proxy"]), null)
  proxy_dns_hosts = var.proxy == null || local.proxy_vip_name == null ? {} : merge(concat([
    for name, h in var.proxy.hosts : { for n in concat([name], h.aliases) : n => { CNAME = "${local.proxy_vip_name}.lylat.space." } }
    ], [
    # The proxy's landing page (proxy.tf var.proxy.landing).
    try({ (var.proxy.landing.name) = { CNAME = "${local.proxy_vip_name}.lylat.space." } }, {}),
  ])...)
  proxy_dns_clashes = sort(setintersection(keys(local.proxy_dns_hosts), setunion(
    keys(local.proxmox_dns_hosts), keys(local.spine_dns_hosts), keys(local.leaf_dns_hosts), keys(local.vm_dns_hosts), keys(local.vip_dns_hosts),
  )))

  generated_dns_hosts = merge(local.proxmox_dns_hosts, local.spine_dns_hosts, local.leaf_dns_hosts, local.vm_dns_hosts, local.vip_dns_hosts, local.proxy_dns_hosts)

  # Merged per record type: a hand-made entry can add other types to a generated name (an AAAA
  # next to the generated A), but can't redefine a generated type (check below).
  dns_hosts_merged = {
    for name in setunion(keys(local.generated_dns_hosts), keys(var.dns_hosts)) :
    name => merge(lookup(local.generated_dns_hosts, name, {}), lookup(var.dns_hosts, name, {}))
  }
  dns_hosts_conflicts = sort(flatten([
    for name, records in var.dns_hosts : [
      for type in keys(records) : "${name} ${type}" if contains(keys(lookup(local.generated_dns_hosts, name, {})), type)
    ]
  ]))

  host_records = flatten([
    for name, records in local.dns_hosts_merged : [
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

check "proxy_names_unique" {
  assert {
    condition     = length(local.proxy_dns_clashes) == 0
    error_message = "Reverse proxy host names (services-config var.proxy.hosts) clash with generated records (VMs, VIPs, Proxmox hosts, leaves, spines): ${join(", ", local.proxy_dns_clashes)}. A CNAME can't share a name with other records."
  }
}

check "dns_hosts_not_generated" {
  assert {
    condition     = length(local.dns_hosts_conflicts) == 0
    error_message = "dns-records.auto.tfvars redefines records that are generated from the inventory (VMs, VIPs, Proxmox hosts, leaves, spines): ${join(", ", local.dns_hosts_conflicts)}. Remove them there (change the inventory instead); other record types on those names are fine."
  }
}

# The services' own VIP settings must match the VIP inventory (one place for addresses and VRIDs).
check "vips_match_services_config" {
  assert {
    condition = alltrue([
      for c in [
        { name = "netbox-vip", vip = try(var.netbox.vip, null), vrid = try(var.netbox.router_id, null), role = "netbox" },
        { name = "dark-triage-vip", vip = try(var.ticketing.vip, null), vrid = try(var.ticketing.router_id, null), role = "ticketing" },
        { name = "proxy-vip", vip = try(var.proxy.vip, null), vrid = try(var.proxy.router_id, null), role = "proxy" },
        { name = "dns-vip", vip = try(var.dns_vrrp.vip, null), vrid = try(var.dns_vrrp.router_id, null), role = "dns" },
        { name = "dns-zone-vip", vip = try(var.dns_vrrp.zone_vip, null), vrid = try(var.dns_vrrp.router_id, null), role = "dns" },
      ] : c.vip == null || try(var.vips[c.name].address == c.vip && var.vips[c.name].vrid == c.vrid && var.vips[c.name].role == c.role, false)
    ])
    error_message = "A VIP in services-config (netbox.vip/router_id, ticketing.vip/router_id, proxy.vip/router_id, dns_vrrp) differs from inventory/auto.tfvars/vips.auto.tfvars (netbox-vip, dark-triage-vip, proxy-vip, dns-vip). Keep them identical."
  }
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
