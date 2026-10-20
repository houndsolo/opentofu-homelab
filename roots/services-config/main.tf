terraform {
  required_version = ">= 1.9.0"
}

locals {
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
    records   = local.custom_records
  })
  deployments = {
    for name, vm in local.dns_vms : name => templatefile("${path.module}/templates/deploy.sh.tftpl", {
      image_b64 = base64encode(var.bind9_image)
      config_b64 = base64encode(templatefile("${path.module}/templates/named.conf.tftpl", {
        address         = local.dns_addresses[name]
        allowed_clients = var.dns_allowed_clients
      }))
      zone_b64 = base64encode(local.zone_data)
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

  provisioner "file" {
    content     = local.deployments[each.key]
    destination = "/tmp/tofu-bind9-${self.id}.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo -n bash /tmp/tofu-bind9-${self.id}.sh",
      "rm -f /tmp/tofu-bind9-${self.id}.sh",
    ]
  }
}

output "dns_addresses" {
  description = "BIND9 service addresses, reachable on TCP and UDP port 53."
  value       = local.dns_addresses
}
