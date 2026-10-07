locals {
  bind9_image = "docker.io/internetsystemsconsortium/bind9:9.20"
  bind9_files = {
    for name, vm in var.network_services.dns : name => {
      named_conf = file("${path.module}/templates/named.conf")
      zone = templatefile("${path.module}/templates/lylat.space.tftpl", {
        servers = { for hostname, server in var.network_services.dns : hostname => split("/", server.service_address)[0] }
      })
      quadlet = <<-EOF
        [Container]
        Image=${local.bind9_image}
        Exec=-g -c /etc/bind/named.conf
        PublishPort=${split("/", vm.service_address)[0]}:53:53/tcp
        PublishPort=${split("/", vm.service_address)[0]}:53:53/udp
        Volume=/etc/bind9:/etc/bind:ro
        Tmpfs=/var/cache/bind:rw,mode=1777

        [Service]
        Restart=always
        TimeoutStartSec=300

        [Install]
        WantedBy=multi-user.target
      EOF
    }
  }
}

# Reapply guest configuration when files, VM placement, or the installer change.
resource "terraform_data" "bind9" {
  for_each = var.network_services.dns
  triggers_replace = [
    local.bind9_files[each.key],
    each.value,
    filesha256("${path.module}/templates/install-bind9.sh.tftpl"),
  ]
  depends_on = [module.dns]

  connection {
    type        = "ssh"
    host        = split("/", each.value.management_address)[0]
    user        = var.network_services.dns_bootstrap.username
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "10m"
  }

  provisioner "remote-exec" {
    inline = [
      "set -eu",
      "sudo cloud-init status --wait",
      "sudo sh -eu <<'BIND9_SETUP'\n${templatefile("${path.module}/templates/install-bind9.sh.tftpl", {
        image           = local.bind9_image
        named_conf      = base64encode(local.bind9_files[each.key].named_conf)
        zone            = base64encode(local.bind9_files[each.key].zone)
        quadlet         = base64encode(local.bind9_files[each.key].quadlet)
        service_address = split("/", each.value.service_address)[0]
        dns1_address    = split("/", var.network_services.dns.dns1.service_address)[0]
        dns2_address    = split("/", var.network_services.dns.dns2.service_address)[0]
      })}\nBIND9_SETUP",
    ]
  }
}
