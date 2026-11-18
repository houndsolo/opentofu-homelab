resource "random_bytes" "dns_tsig" {
  count  = nonsensitive(var.dns_tsig_secret == null) ? 1 : 0
  length = 32
}

locals {
  dns_tsig_secret = var.dns_tsig_secret != null ? var.dns_tsig_secret : random_bytes.dns_tsig[0].base64
  dns_vms = {
    for name, vm in var.vms : name => vm
    if vm.owner == "services-vms" && vm.role == "dns"
  }
  # BIND listens on the one data NIC with an address and a gateway (the HA L2VNI NIC
  # has no gateway); the vms validation checks it.
  dns_addresses = { for name in keys(local.dns_vms) : name => one(local.vm_gateway_addresses[name]) }
  zone_data = templatefile("${path.module}/templates/lylat.space.zone.tftpl", {
    addresses = local.dns_addresses
    primary   = var.dns_primary
  })
  reverse_zone_data = templatefile("${path.module}/templates/reverse.zone.tftpl", {
    addresses = local.dns_addresses
    primary   = var.dns_primary
  })
  # BIND on each DNS VM (modules/services/quadlet-deploy). named.conf and the key are checked in throwaway
  # containers before anything is installed; a change to either is a reload (bind9.service's ExecReload,
  # templates/bind9-reload.sh: SIGHUP, fails unless named logs a successful reload), a unit change a restart.
  # The primary's seed zones are installed once and never again: the live zones take RFC 2136 updates.
  bind9_check = "podman run --rm --network=none --entrypoint named-checkconf -v \"$stage/etc/bind9-container:/etc/bind:ro\" '${local.container_images.bind9}' /etc/bind/named.conf"
  bind9_check_zone = {
    for zone, file in { "lylat.space" = "lylat.space.zone", "10.in-addr.arpa" = "10.in-addr.arpa.zone" } : zone =>
    "podman run --rm --network=none --entrypoint named-checkzone -v \"$stage/var/lib/bind9-container/primary:/zones:ro\" '${local.container_images.bind9}' ${zone} /zones/${file}"
  }
  bind9_files = {
    for name, vm in local.dns_vms : name => concat([
      { path = "/etc/containers/systemd/bind9.container", units = ["bind9"], content = templatefile("${path.module}/templates/bind9.container.tftpl", {
        image      = local.container_images.bind9
        stats_port = local.dns_stats_port # dns-bind-exporter.tf
      }) },
      { path = "/usr/local/sbin/bind9-reload", mode = "0755", content = file("${path.module}/templates/bind9-reload.sh") },
      { path = "/etc/bind9-container/named.conf", units = ["bind9"], content = templatefile("${path.module}/templates/named.conf.tftpl", {
        address = local.dns_addresses[name]
        # vip: the keepalived VIP; BIND binds it when it appears. extra_listen: the lylat-dns NIC's
        # address and the zone VIP (10.53.53.53), when the VM has that NIC.
        vip                 = local.dns_vip
        extra_listen        = local.dns_nics[name].zone == null ? [] : [local.dns_nics[name].zone.address, local.dns_zone_vip]
        allowed_clients     = var.dns_allowed_clients
        transfer_clients    = var.dns_transfer_clients
        primary             = name == var.dns_primary
        primary_address     = local.dns_addresses[var.dns_primary]
        secondary_addresses = [for peer, address in local.dns_addresses : address if peer != var.dns_primary]
        stats_port          = local.dns_stats_port # dns-bind-exporter.tf
      }) },
      # 0640 root:bind (gid 53 in the image).
      { path = "/etc/bind9-container/tsig.key", mode = "0640", owner = "0:53", units = ["bind9"], content = templatefile("${path.module}/templates/tsig.key.tftpl", {
        secret = local.dns_tsig_secret
      }) },
      ], [for f in [
        { path = "/var/lib/bind9-container/primary/lylat.space.zone", mode = "0640", owner = "53:53", once = true, content = local.zone_data },
        { path = "/var/lib/bind9-container/primary/10.in-addr.arpa.zone", mode = "0640", owner = "53:53", once = true, content = local.reverse_zone_data },
    ] : f if name == var.dns_primary])
  }
}

module "bind9" {
  source   = "../../modules/services/quadlet-deploy"
  for_each = local.dns_vms

  name   = "bind9"
  host   = each.key
  files  = local.bind9_files[each.key]
  units  = ["bind9"]
  images = [local.container_images.bind9]
  dirs = [
    { path = "/etc/bind9-container" },
    { path = "/var/lib/bind9-container", mode = "0750", owner = "53:53" },
    { path = "/var/lib/bind9-container/primary", mode = "0750", owner = "53:53" },
    { path = "/var/lib/bind9-container/secondary", mode = "0750", owner = "53:53" },
  ]
  checks = concat([local.bind9_check], each.key == var.dns_primary ? values(local.bind9_check_zone) : [])
}

resource "terraform_data" "bind9" {
  for_each = local.dns_vms

  triggers_replace = [
    sha256(module.bind9[each.key].script),
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
    content     = module.bind9[each.key].script
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
