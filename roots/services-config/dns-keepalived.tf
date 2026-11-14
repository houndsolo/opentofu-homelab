# keepalived on the DNS pair: VIP var.dns_vrrp.vip on BIND's service NIC, VRRP adverts
# unicast over the HA L2VNI (l2vnis.ha_dns). Separate from terraform_data.bind9, so
# changing it never restarts BIND, and a reload keeps the current MASTER.
locals {
  dns_vip      = var.dns_vrrp == null ? null : split("/", var.dns_vrrp.vip)[0]
  dns_zone_vip = try(split("/", var.dns_vrrp.zone_vip)[0], null)

  # network_devices[i] is eth<i+1> (eth0 is management; checked with ip -br a on dns01).
  dns_nics = {
    for name, vm in local.dns_vms : name => {
      service = one([for i, nic in vm.network_devices : "eth${i + 1}" if nic.ipv4_address != null && nic.ipv4_gateway != null])
      # lylat-dns NIC (zone_vip, BIND listens on it too); null without zone_vip or such a NIC.
      zone = try(one([
        for i, nic in vm.network_devices : {
          interface = "eth${i + 1}"
          address   = split("/", nic.ipv4_address)[0]
        } if nic.vlan_id == var.dns_vrrp.zone_vlan_id && nic.ipv4_address != null && var.dns_vrrp.zone_vip != null
      ]), null)
      ha = one([
        for i, nic in vm.network_devices : {
          interface = "eth${i + 1}"
          address   = split("/", nic.ipv4_address)[0]
        } if nic.vlan_id == var.l2vnis["ha_dns"].vlan_id && nic.ipv4_address != null
      ])
    }
  }

  dns_keepalived_scripts = var.dns_vrrp == null ? {} : {
    for name, vm in local.dns_vms : name => templatefile("${path.module}/templates/dns-keepalived.sh.tftpl", {
      conf_b64 = base64encode(templatefile("${path.module}/templates/dns-keepalived.conf.tftpl", {
        host         = name
        ha_interface = local.dns_nics[name].ha.interface
        ha_address   = local.dns_nics[name].ha.address
        peers        = [for peer, nics in local.dns_nics : nics.ha.address if peer != name]
        router_id    = var.dns_vrrp.router_id
        # Only the first election: nopreempt keeps the VIP where it is afterwards.
        priority       = name == var.dns_primary ? 150 : 100
        vip            = var.dns_vrrp.vip
        interface      = local.dns_nics[name].service
        zone_vip       = local.dns_nics[name].zone == null ? null : var.dns_vrrp.zone_vip
        zone_interface = try(local.dns_nics[name].zone.interface, null)
      }))
      check_b64 = base64encode(templatefile("${path.module}/templates/dns-keepalived-check.sh.tftpl", {
        address = local.dns_addresses[name]
      }))
    })
  }
}

resource "terraform_data" "dns_keepalived" {
  for_each = local.dns_keepalived_scripts

  lifecycle {
    precondition {
      condition     = local.dns_nics[each.key].ha != null
      error_message = "Each DNS VM needs a NIC on the ha_dns L2VNI (VLAN ${var.l2vnis["ha_dns"].vlan_id}) with an address."
    }
  }

  triggers_replace = [
    sha256(each.value),
    local.dns_vms[each.key].management_address,
    local.dns_vms[each.key].vm_id,
    local.dns_vms[each.key].config.ssh_username,
    var.dns_deploy_revision,
  ]

  connection {
    type        = "ssh"
    host        = split("/", local.dns_vms[each.key].management_address)[0]
    user        = local.dns_vms[each.key].config.ssh_username
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = ["install -d -m 0700 /tmp/tofu-keepalived-${self.id}"]
  }

  provisioner "file" {
    content     = each.value
    destination = "/tmp/tofu-keepalived-${self.id}/dns-keepalived.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo -n bash /tmp/tofu-keepalived-${self.id}/dns-keepalived.sh",
      "rm -rf /tmp/tofu-keepalived-${self.id}",
    ]
  }

  # BIND must already be up (it listens on the VIP once keepalived adds it).
  depends_on = [terraform_data.bind9]
}

output "dns_vip" {
  description = "DNS VIP held by keepalived on the DNS pair (null when dns_vrrp is null)."
  value       = local.dns_vip
}
