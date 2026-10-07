# OpenTofu generates and retains the key; no manual TSIG input is needed.
resource "random_bytes" "dns_tsig" {
  length = 32
}

provider "dns" {
  update {
    server    = split("/", var.network_services.dns.dns1.service_address)[0]
    transport = "tcp"
    # Keep all authentication fields unknown together on the first plan.
    key_name      = random_bytes.dns_tsig.base64 != "" ? "opentofu.lylat.space." : ""
    key_algorithm = random_bytes.dns_tsig.base64 != "" ? "hmac-sha256" : ""
    key_secret    = random_bytes.dns_tsig.base64
  }
}

resource "dns_a_record_set" "servers" {
  for_each   = var.network_services.dns
  zone       = "lylat.space."
  name       = each.key
  addresses  = [split("/", each.value.service_address)[0]]
  ttl        = 300
  depends_on = [terraform_data.bind9]
}

resource "dns_a_record_set" "proxmox" {
  for_each   = merge(var.nodes.proxmox_cluster, var.nodes.proxmox)
  zone       = "lylat.space."
  name       = each.key
  addresses  = [cidrhost(local.pve_mgmt_subnet, each.value.id)]
  ttl        = 300
  depends_on = [terraform_data.bind9]
}

resource "dns_a_record_set" "records" {
  for_each   = { for name, record in var.records : name => record if record.a != null }
  zone       = "lylat.space."
  name       = each.key
  addresses  = [each.value.a]
  ttl        = 300
  depends_on = [terraform_data.bind9]
}

resource "dns_aaaa_record_set" "records" {
  for_each   = { for name, record in var.records : name => record if record.aaaa != null }
  zone       = "lylat.space."
  name       = each.key
  addresses  = [each.value.aaaa]
  ttl        = 300
  depends_on = [terraform_data.bind9]
}

resource "dns_cname_record" "records" {
  for_each   = { for name, record in var.records : name => record if record.cname != null }
  zone       = "lylat.space."
  name       = each.key
  cname      = each.value.cname
  ttl        = 300
  depends_on = [terraform_data.bind9]
}
