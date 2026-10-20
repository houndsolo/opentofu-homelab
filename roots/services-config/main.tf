terraform {
  required_version = ">= 1.9.0"
  required_providers {
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
  }
}

resource "random_bytes" "dns_tsig" {
  count  = nonsensitive(var.dns_tsig_secret == null) ? 1 : 0
  length = 32
}

locals {
  dns_tsig_secret = var.dns_tsig_secret != null ? var.dns_tsig_secret : random_bytes.dns_tsig[0].base64
  dns_vms = {
    for name, vm in var.vms : name => vm
    if vm.owner == "services-vms-dns"
  }
  dns_addresses = {
    for name, vm in local.dns_vms : name => split("/", one([
      for nic in vm.network_devices : nic.ipv4_address
      if nic.bridge == "vmbr4000" && nic.vlan_id == 8
    ]))[0]
  }
  zone_data = templatefile("${path.module}/templates/lylat.space.zone.tftpl", {
    addresses = local.dns_addresses
    records   = []
    primary   = var.dns_primary
  })
  deployments = {
    for name, vm in local.dns_vms : name => templatefile("${path.module}/templates/deploy.sh.tftpl", {
      image_b64 = base64encode(var.bind9_image)
      config_b64 = base64encode(templatefile("${path.module}/templates/named.conf.tftpl", {
        address             = local.dns_addresses[name]
        allowed_clients     = var.dns_allowed_clients
        primary             = name == var.dns_primary
        primary_address     = local.dns_addresses[var.dns_primary]
        secondary_addresses = [for peer, address in local.dns_addresses : address if peer != var.dns_primary]
      }))
      zone_b64 = base64encode(local.zone_data)
      primary  = name == var.dns_primary
      key_b64 = base64encode(templatefile("${path.module}/templates/tsig.key.tftpl", {
        secret = local.dns_tsig_secret
      }))
      quadlet_b64 = base64encode(templatefile("${path.module}/templates/bind9.container.tftpl", {
        image = var.bind9_image
      }))
    })
  }
}

resource "terraform_data" "bind9" {
  for_each = local.dns_vms

  triggers_replace = [
    sha256(local.deployments[each.key]),
    each.value.management_address,
    each.value.vm_id,
    each.value.config.ssh_username,
    var.dns_deploy_revision,
  ]

  connection {
    type        = "ssh"
    host        = split("/", each.value.management_address)[0]
    user        = each.value.config.ssh_username
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = ["install -d -m 0700 /tmp/tofu-bind9-${self.id}"]
  }

  provisioner "file" {
    content     = local.deployments[each.key]
    destination = "/tmp/tofu-bind9-${self.id}/deploy.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo -n bash /tmp/tofu-bind9-${self.id}/deploy.sh",
      "rm -rf /tmp/tofu-bind9-${self.id}",
    ]
  }
}

output "dns_addresses" {
  description = "BIND9 service addresses, reachable on TCP and UDP port 53."
  value       = local.dns_addresses
}

resource "terraform_data" "dns_records" {
  lifecycle {
    precondition {
      condition = alltrue([
        for records in values(local.record_sets) :
        length(distinct([for record in records : record.ttl])) == 1
      ])
      error_message = "All records in an owner/type RRset must have the same TTL."
    }
    precondition {
      condition = alltrue([
        for record in local.custom_records :
        !contains(["ANY", "AXFR", "IXFR", "OPT", "TSIG", "TKEY", "SOA"], record.type) &&
        !(record.name == "@" && record.type == "NS") &&
        !(contains(keys(local.dns_vms), lower(trimsuffix(record.name, "."))) && record.type == "A")
      ])
      error_message = "SOA, apex NS and DNS VM A records are bootstrap-owned; DNS protocol meta-types cannot be managed as data."
    }
  }
  triggers_replace = [
    sha256(local.record_deployment),
    terraform_data.bind9[var.dns_primary].id,
  ]

  connection {
    type        = "ssh"
    host        = split("/", local.dns_vms[var.dns_primary].management_address)[0]
    user        = local.dns_vms[var.dns_primary].config.ssh_username
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "5m"
  }

  provisioner "file" {
    content     = local.record_deployment
    destination = "/tmp/tofu-dns-records-${self.id}.py"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo -n python3 /tmp/tofu-dns-records-${self.id}.py",
      "rm -f /tmp/tofu-dns-records-${self.id}.py",
    ]
  }

  depends_on = [terraform_data.bind9]
}
