# dark-triage helpdesk (github.com/houndsolo/vc-ticketing-system): Python stdlib (+ psycopg),
# user accounts (admin/user roles), data in Postgres on the Patroni cluster. Built on each VM
# from a pinned commit and run as a rootful Podman Quadlet container.
#
# HA: every VM with role "ticketing" runs the app (stateless: sessions, tokens and tickets live
# in Postgres). keepalived holds var.ticketing.vip on the VLAN 2 NIC of the healthy node whose
# /api/health answers 200 (the app reaches its database); adverts go unicast over the HA L2VNI
# (l2vnis.ha_triage). The app is published on the node's own VLAN 2 address and on the VIP
# (net.ipv4.ip_nonlocal_bind, so the BACKUP can bind it too). The first start bootstraps the
# admin account from ADMIN_USERNAME / ADMIN_PASSWORD (ignored once users exist).
#
# Deploys are canary-first: the first VM (sorted by name) is deployed and must pass its health
# check before the others are touched, so a broken build never takes down every node.
variable "ticketing" {
  description = "dark-triage source (pinned commit), listen ports, database and VIP. null = don't deploy."
  type = object({
    repo   = optional(string, "houndsolo/vc-ticketing-system")
    commit = optional(string, "651f6af8e2e51af00163cc34a9aea2339efc70c2")
    admin  = optional(string, "admin") # bootstrap admin username
    # Postgres on the Patroni cluster (monitoring-config postgres_apps creates role + database
    # "triage" and allows the app VMs' backend addresses). Used only when app_db_passwords has
    # a "triage" entry and postgres = true; otherwise the app keeps SQLite in /var/lib/dark-triage.
    postgres = optional(bool, true)
    database = optional(object({
      host = optional(string, "10.56.14.104") # Patroni VIP (lylat-data)
      port = optional(number, 5432)
      name = optional(string, "triage")
      user = optional(string, "triage")
    }), {})
    ports = optional(list(number), [80, 3000])
    # keepalived VIP on VLAN 2 (dark-triage-vip.lylat.space; users reach https://dark-triage.lylat.space
    # through the reverse proxy, proxy.tf). null = no keepalived.
    vip       = optional(string, "10.52.13.105/16")
    router_id = optional(number, 105) # = the VIP's last octet, like Grafana 100, Loki 101, monitoring 102, Mimir 103, Postgres 104
    ha_l2vni  = optional(string, "ha_triage")
  })
  default = {}

  validation {
    condition = var.ticketing == null || try(
      (var.ticketing.vip == null || (can(cidrhost(var.ticketing.vip, 0)) && strcontains(var.ticketing.vip, "/"))) &&
      var.ticketing.router_id >= 1 && var.ticketing.router_id <= 255, false
    )
    error_message = "ticketing.vip must be an IPv4 address with prefix length (e.g. 10.52.13.105/16), router_id 1..255."
  }
}

resource "random_password" "ticketing" {
  count   = var.ticketing != null ? 1 : 0
  length  = 24
  special = false
}

resource "random_password" "ticketing_vrrp" {
  count   = var.ticketing != null ? 1 : 0
  length  = 8 # VRRP PASS authentication uses at most 8 characters.
  special = false
}

locals {
  ticketing_vms   = { for name, vm in var.vms : name => vm if vm.owner == "services-vms" && vm.role == "ticketing" }
  ticketing_names = sort(keys(local.ticketing_vms))
  ticketing_vip   = var.ticketing == null ? null : try(split("/", var.ticketing.vip)[0], null)
  ticketing_ha    = var.ticketing != null && local.ticketing_vip != null

  # network_devices[i] is eth<i+1> (eth0 is management). The app listens on the VLAN 2 NIC (the one
  # with the gateway); keepalived adverts use the NIC on the HA L2VNI.
  ticketing_nics = {
    for name, vm in local.ticketing_vms : name => {
      service = one([for i, nic in vm.network_devices : { interface = "eth${i + 1}", address = split("/", nic.ipv4_address)[0] } if nic.ipv4_address != null && nic.ipv4_gateway != null])
      ha = !local.ticketing_ha ? null : one([
        for i, nic in vm.network_devices : { interface = "eth${i + 1}", address = split("/", nic.ipv4_address)[0] }
        if nic.vlan_id == var.l2vnis[var.ticketing.ha_l2vni].vlan_id && nic.ipv4_address != null
      ])
    }
  }
  ticketing_listen = { for name, n in local.ticketing_nics : name => n.service.address }

  ticketing_database_url = (var.ticketing == null ? false : var.ticketing.postgres && contains(keys(var.app_db_passwords), "triage")) ? format(
    "postgresql://%s:%s@%s:%d/%s?sslmode=require&connect_timeout=5",
    var.ticketing.database.user, urlencode(var.app_db_passwords["triage"]), var.ticketing.database.host,
    var.ticketing.database.port, var.ticketing.database.name,
  ) : null

  ticketing_script = var.ticketing == null ? {} : {
    for name, vm in local.ticketing_vms : name => templatefile("${path.module}/templates/ticketing-deploy.sh.tftpl", {
      tarball = "https://codeload.github.com/${var.ticketing.repo}/tar.gz/${var.ticketing.commit}"
      image   = "localhost/dark-triage:${substr(var.ticketing.commit, 0, 12)}"
      listen  = local.ticketing_listen[name]
      ha      = local.ticketing_ha
      unit_b64 = base64encode(templatefile("${path.module}/templates/dark-triage.container.tftpl", {
        image     = "localhost/dark-triage:${substr(var.ticketing.commit, 0, 12)}"
        addresses = compact([local.ticketing_listen[name], local.ticketing_vip])
        ports     = var.ticketing.ports
      }))
      env_b64 = base64encode(join("", [
        "ADMIN_USERNAME=${var.ticketing.admin}\n",
        "ADMIN_PASSWORD=${random_password.ticketing[0].result}\n",
        local.ticketing_database_url == null ? "" : "DATABASE_URL=${local.ticketing_database_url}\n",
      ]))
      keepalived_b64 = !local.ticketing_ha ? "" : base64encode(templatefile("${path.module}/templates/ticketing-keepalived.conf.tftpl", {
        host         = name
        ha_interface = local.ticketing_nics[name].ha.interface
        ha_address   = local.ticketing_nics[name].ha.address
        peers        = [for peer, n in local.ticketing_nics : n.ha.address if peer != name]
        router_id    = var.ticketing.router_id
        # Only the first election: nopreempt keeps the VIP where it is afterwards.
        priority  = name == local.ticketing_names[0] ? 150 : 100
        auth_pass = random_password.ticketing_vrrp[0].result
        vip       = var.ticketing.vip
        interface = local.ticketing_nics[name].service.interface
      }))
      check_b64 = base64encode(templatefile("${path.module}/templates/ticketing-keepalived-check.sh.tftpl", {
        url = "http://${local.ticketing_listen[name]}:3000/api/health"
      }))
    })
  }

  # Canary first: the first VM by name, then everything else (depends_on).
  ticketing_canary = { for name, s in local.ticketing_script : name => s if name == local.ticketing_names[0] }
  ticketing_rest   = { for name, s in local.ticketing_script : name => s if name != local.ticketing_names[0] }
}

resource "terraform_data" "ticketing_canary" {
  for_each = local.ticketing_canary

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

resource "terraform_data" "ticketing" {
  for_each   = local.ticketing_rest
  depends_on = [terraform_data.ticketing_canary]

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
  description = "dark-triage helpdesk URLs: the VIP and each node."
  value = merge(
    local.ticketing_vip == null ? {} : { vip = "http://${local.ticketing_vip}/ (users: https://dark-triage.lylat.space/)" },
    { for name, ip in local.ticketing_listen : name => "http://${ip}/" },
  )
}

output "ticketing_admin_password" {
  description = "dark-triage bootstrap admin password (user: var.ticketing.admin; tofu output -raw ticketing_admin_password). Only used when the database has no users yet."
  value       = var.ticketing != null ? random_password.ticketing[0].result : null
  sensitive   = true
}

variable "app_db_passwords" {
  description = "Postgres passwords of app databases on the Patroni cluster (git-ignored app-db.secret.auto.tfvars, shared with monitoring-config)."
  sensitive   = true
  type        = map(string)
  default     = {}
}
