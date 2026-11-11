# dark-triage helpdesk (github.com/houndsolo/vc-ticketing-system): Python stdlib + SQLite, user
# accounts (admin/user roles). The first start bootstraps the admin account from ADMIN_USERNAME /
# ADMIN_PASSWORD (ignored once users exist; the admin then creates the other users). Built on the VM from a pinned commit and run as a rootful Podman Quadlet
# container, published on the VM's VLAN 2 address (:80 and :3000). Data: /var/lib/dark-triage.
variable "ticketing" {
  description = "dark-triage source (pinned commit) and listen ports. null = don't deploy."
  type = object({
    repo   = optional(string, "houndsolo/vc-ticketing-system")
    commit = optional(string, "ca58eb81fc85253bad75b36aa1a1981d9776a9bb")
    admin  = optional(string, "admin") # bootstrap admin username
    ports  = optional(list(number), [80, 3000])
  })
  default = {}
}

resource "random_password" "ticketing" {
  count   = var.ticketing != null ? 1 : 0
  length  = 24
  special = false
}

locals {
  ticketing_vms = { for name, vm in var.vms : name => vm if vm.owner == "services-vms" && vm.role == "ticketing" }
  # The app listens on the VLAN 2 (data) NIC: the one with a gateway.
  ticketing_listen = {
    for name, vm in local.ticketing_vms : name => split("/", one([
      for nic in vm.network_devices : nic.ipv4_address if nic.ipv4_address != null && nic.ipv4_gateway != null
    ]))[0]
  }
  ticketing_script = var.ticketing == null ? {} : {
    for name, vm in local.ticketing_vms : name => templatefile("${path.module}/templates/ticketing-deploy.sh.tftpl", {
      tarball = "https://codeload.github.com/${var.ticketing.repo}/tar.gz/${var.ticketing.commit}"
      image   = "localhost/dark-triage:${substr(var.ticketing.commit, 0, 12)}"
      listen  = local.ticketing_listen[name]
      ports   = var.ticketing.ports
      unit_b64 = base64encode(templatefile("${path.module}/templates/dark-triage.container.tftpl", {
        image  = "localhost/dark-triage:${substr(var.ticketing.commit, 0, 12)}"
        listen = local.ticketing_listen[name]
        ports  = var.ticketing.ports
      }))
      env_b64 = base64encode("ADMIN_USERNAME=${var.ticketing.admin}\nADMIN_PASSWORD=${random_password.ticketing[0].result}\n")
    })
  }
}

resource "terraform_data" "ticketing" {
  for_each = local.ticketing_script

  triggers_replace = [
    sha256(each.value),
    local.ticketing_vms[each.key].management_address,
    local.ticketing_vms[each.key].vm_id,
  ]

  connection {
    type        = "ssh"
    host        = split("/", local.ticketing_vms[each.key].management_address)[0]
    user        = local.ticketing_vms[each.key].config.ssh_username
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = ["install -d -m 0700 /tmp/tofu-ticketing-${self.id}"]
  }

  provisioner "file" {
    content     = each.value
    destination = "/tmp/tofu-ticketing-${self.id}/deploy.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "rc=0; sudo -n bash /tmp/tofu-ticketing-${self.id}/deploy.sh || rc=$?; rm -rf /tmp/tofu-ticketing-${self.id}; exit $rc",
    ]
  }
}

output "ticketing_url" {
  description = "dark-triage helpdesk URL(s)."
  value       = { for name, ip in local.ticketing_listen : name => "http://${ip}/ (http://dark-triage.lylat.space/)" }
}

output "ticketing_admin_password" {
  description = "dark-triage bootstrap admin password (user: var.ticketing.admin; tofu output -raw ticketing_admin_password). Only used when the database has no users yet."
  value       = var.ticketing != null ? random_password.ticketing[0].result : null
  sensitive   = true
}
