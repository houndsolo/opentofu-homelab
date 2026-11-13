# Copy the certificate to every proxy VM over SSH (management address) and reload nginx if it
# runs. Re-runs when the certificate changes (renewal) or the VM is rebuilt. The files go through
# a private temp dir and are installed as root: fullchain.pem 0644, privkey.pem 0600.
locals {
  certificate_fullchain = "${acme_certificate.svc.certificate_pem}${acme_certificate.svc.issuer_pem}"
}

resource "terraform_data" "deploy" {
  for_each = local.proxy_vms

  triggers_replace = [
    acme_certificate.svc.certificate_serial,
    each.value.management_address,
    each.value.vm_id,
    var.certificate.directory,
  ]

  connection {
    type        = "ssh"
    host        = split("/", each.value.management_address)[0]
    user        = each.value.config.ssh_username
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = ["install -d -m 0700 /tmp/tofu-certs-${self.id}"]
  }

  provisioner "file" {
    content     = local.certificate_fullchain
    destination = "/tmp/tofu-certs-${self.id}/fullchain.pem"
  }

  provisioner "file" {
    content     = acme_certificate.svc.private_key_pem
    destination = "/tmp/tofu-certs-${self.id}/privkey.pem"
  }

  provisioner "remote-exec" {
    inline = [
      "set -e",
      "t=/tmp/tofu-certs-${self.id}",
      "d='${var.certificate.directory}'",
      "trap 'rm -rf \"$t\"' EXIT",
      "sudo -n install -d -m 0755 -o root -g root \"$d\"",
      "sudo -n install -m 0644 -o root -g root \"$t/fullchain.pem\" \"$d/fullchain.pem\"",
      "sudo -n install -m 0600 -o root -g root \"$t/privkey.pem\" \"$d/privkey.pem\"",
      "if systemctl is-active --quiet nginx; then sudo -n systemctl reload nginx; fi",
      "sudo -n openssl x509 -in \"$d/fullchain.pem\" -noout -subject -issuer -enddate",
    ]
  }
}
