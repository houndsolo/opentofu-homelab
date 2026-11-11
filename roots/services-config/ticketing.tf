# dark_triage helpdesk (github.com/houndsolo/vc-ticketing-system): Python stdlib + SQLite, one
# shared ACCESS_PASSWORD. Built on the VM from a pinned commit and run as a rootful Podman Quadlet
# container, published on the VM's VLAN 2 address (:80 and :3000). Data: /var/lib/dark-triage.
variable "ticketing" {
  description = "dark_triage source (pinned commit) and listen ports. null = don't deploy."
  type = object({
    repo   = optional(string, "houndsolo/vc-ticketing-system")
    commit = optional(string, "378739c5a6681973ddc0c3cb98cf9387836470cf")
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
      env_b64 = base64encode("ACCESS_PASSWORD=${random_password.ticketing[0].result}\n")
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
  description = "dark_triage helpdesk URL(s)."
  value       = { for name, ip in local.ticketing_listen : name => "http://${ip}/ (http://triage.lylat.space/)" }
}

output "ticketing_password" {
  description = "dark_triage shared ACCESS_PASSWORD (tofu output -raw ticketing_password)."
  value       = var.ticketing != null ? random_password.ticketing[0].result : null
  sensitive   = true
}
