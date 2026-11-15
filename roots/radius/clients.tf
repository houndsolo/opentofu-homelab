# RADIUS clients -> /etc/radius/clients.conf on every radius VM, canary first.
resource "random_password" "client" {
  for_each = var.clients
  length   = 32
  special  = false
}

locals {
  clients_conf = templatefile("${path.module}/templates/clients.conf.tftpl", {
    clients = { for n, c in var.clients : n => merge(c, { secret = random_password.client[n].result }) }
  })
  clients_script = templatefile("${path.module}/templates/clients-deploy.sh.tftpl", {
    conf_b64 = base64encode(local.clients_conf)
    count    = length(var.clients)
  })
}

resource "terraform_data" "clients_canary" {
  for_each = local.canary == null ? {} : { (local.canary) = local.radius_vms[local.canary] }

  triggers_replace = [sha256(local.clients_script), each.value.management_address, each.value.vm_id]

  connection {
    type        = "ssh"
    host        = split("/", each.value.management_address)[0]
    user        = each.value.config.ssh_username
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = ["install -d -m 0700 /tmp/tofu-radius-clients-${self.id}"]
  }

  provisioner "file" {
    content     = local.clients_script
    destination = "/tmp/tofu-radius-clients-${self.id}/deploy.sh"
  }

  provisioner "remote-exec" {
    inline = ["rc=0; sudo -n bash /tmp/tofu-radius-clients-${self.id}/deploy.sh || rc=$?; rm -rf /tmp/tofu-radius-clients-${self.id}; exit $rc"]
  }
}

resource "terraform_data" "clients" {
  for_each   = { for n, vm in local.radius_vms : n => vm if n != local.canary }
  depends_on = [terraform_data.clients_canary]

  triggers_replace = [sha256(local.clients_script), each.value.management_address, each.value.vm_id]

  connection {
    type        = "ssh"
    host        = split("/", each.value.management_address)[0]
    user        = each.value.config.ssh_username
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = ["install -d -m 0700 /tmp/tofu-radius-clients-${self.id}"]
  }

  provisioner "file" {
    content     = local.clients_script
    destination = "/tmp/tofu-radius-clients-${self.id}/deploy.sh"
  }

  provisioner "remote-exec" {
    inline = ["rc=0; sudo -n bash /tmp/tofu-radius-clients-${self.id}/deploy.sh || rc=$?; rm -rf /tmp/tofu-radius-clients-${self.id}; exit $rc"]
  }
}
