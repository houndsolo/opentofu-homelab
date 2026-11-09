# The DNS VMs' journal (BIND's container logs included: Podman logs to journald with
# SYSLOG_IDENTIFIER=bind9) goes to Loki as syslog through rsyslog. Separate from
# terraform_data.bind9, so changing it never restarts BIND.
locals {
  dns_syslog_script = var.dns_syslog == null ? null : templatefile("${path.module}/templates/rsyslog-loki.sh.tftpl", {
    conf_b64 = base64encode(templatefile("${path.module}/templates/rsyslog-loki.conf.tftpl", var.dns_syslog))
  })
}

resource "terraform_data" "dns_syslog" {
  for_each = var.dns_syslog == null ? {} : local.dns_vms

  triggers_replace = [
    sha256(local.dns_syslog_script),
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
    inline = ["install -d -m 0700 /tmp/tofu-syslog-${self.id}"]
  }

  provisioner "file" {
    content     = local.dns_syslog_script
    destination = "/tmp/tofu-syslog-${self.id}/rsyslog-loki.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo -n bash /tmp/tofu-syslog-${self.id}/rsyslog-loki.sh",
      "rm -rf /tmp/tofu-syslog-${self.id}",
    ]
  }
}
