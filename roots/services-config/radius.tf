# FreeRADIUS 3.2 on the role = "radius" VMs (rad01/rad02). No VIP and no keepalived: RADIUS clients (WLCs,
# switches, routers) list both servers and fail over themselves, and a multi-round EAP exchange must stay on
# one server, which a VIP or load balancer could break.
#
# Per server, one Podman Quadlet container (official freeradius-server image, host network so the server sees
# real client source addresses) with the image's default config plus the sql module from here:
#   mods-enabled/sql   rlm_sql -> Patroni via postgres-vip, database "radius" (role + pg_hba from
#                  monitoring-config postgres_app_roles, password app_db_passwords["radius"]), TLS without
#                  certificate checks. The default and inner-tunnel sites use it through their "-sql" lines:
#                  users/groups (radcheck, radreply, radusergroup, ...), accounting (radacct), every auth
#                  result (radpostauth). Both servers read the same tables.
#
# Deliberately NOT here (owner's call: a separate project): RADIUS users and passwords, the RADIUS clients
# (devices) and their shared secrets, certificates (EAP). The image's clients.conf only knows localhost
# (secret testing123), so until that project adds clients, no device can talk to these servers.
# The canary's deploy creates the empty tables (the image's postgresql/schema.sql) when they don't exist.
#
# Postgres down = SQL users can't log in (the servers keep running: the pool starts empty, retries every 5 s).
variable "radius" {
  description = "FreeRADIUS (pair on the role = \"radius\" VMs): the database it uses. null = don't deploy."
  type = object({
    database = optional(object({
      host     = optional(string, "10.56.14.104") # Patroni VIP (lylat-data)
      port     = optional(number, 5432)
      name     = optional(string, "radius")
      user     = optional(string, "radius")
      pool_max = optional(number, 8) # connections per server
    }), {})
  })
  default = {}
}

locals {
  radius_vms   = { for name, vm in var.vms : name => vm if vm.owner == "services-vms" && vm.role == "radius" }
  radius_names = sort(keys(local.radius_vms))
  # Needs its database password (app-db.secret.auto.tfvars) and monitoring-config's database + role.
  radius_enabled = var.radius != null && length(local.radius_vms) > 0 && nonsensitive(contains(keys(var.app_db_passwords), "radius"))

  radius_sql = !local.radius_enabled ? "" : templatefile("${path.module}/templates/radius-sql.tftpl", {
    db_host  = var.radius.database.host
    db_port  = var.radius.database.port
    db_name  = var.radius.database.name
    db_user  = var.radius.database.user
    pool_max = var.radius.database.pool_max
  })

  radius_script = !local.radius_enabled ? {} : {
    for name, vm in local.radius_vms : name => templatefile("${path.module}/templates/radius-deploy.sh.tftpl", {
      image   = local.container_images.freeradius
      canary  = name == local.radius_names[0]
      db_host = var.radius.database.host
      db_port = var.radius.database.port
      db_name = var.radius.database.name
      db_user = var.radius.database.user
      # base64 so secrets never appear in the script as plain text (they are still in tofu's state).
      sql_b64 = base64encode(local.radius_sql)
      env_b64 = base64encode("RADIUS_DB_PASSWORD=${var.app_db_passwords["radius"]}\n")
      unit_b64 = base64encode(templatefile("${path.module}/templates/radius.container.tftpl", {
        image = local.container_images.freeradius
      }))
      pgpass_b64 = base64encode("${var.radius.database.host}:${var.radius.database.port}:${var.radius.database.name}:${var.radius.database.user}:${var.app_db_passwords["radius"]}\n")
    })
  }

  # Canary first: the first VM by name loads the schema before the other server deploys.
  radius_canary = { for name, s in local.radius_script : name => s if name == local.radius_names[0] }
  radius_rest   = { for name, s in local.radius_script : name => s if name != local.radius_names[0] }
}

resource "terraform_data" "radius_canary" {
  for_each = local.radius_canary

  triggers_replace = [
    sha256(each.value),
    local.radius_vms[each.key].management_address,
    local.radius_vms[each.key].vm_id,
  ]

  connection {
    type        = "ssh"
    host        = split("/", local.radius_vms[each.key].management_address)[0]
    user        = local.radius_vms[each.key].config.ssh_username
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = ["install -d -m 0700 /tmp/tofu-radius-${self.id}"]
  }

  provisioner "file" {
    content     = each.value
    destination = "/tmp/tofu-radius-${self.id}/deploy.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "rc=0; sudo -n bash /tmp/tofu-radius-${self.id}/deploy.sh || rc=$?; rm -rf /tmp/tofu-radius-${self.id}; exit $rc",
    ]
  }
}

resource "terraform_data" "radius" {
  for_each   = local.radius_rest
  depends_on = [terraform_data.radius_canary]

  triggers_replace = [
    sha256(each.value),
    local.radius_vms[each.key].management_address,
    local.radius_vms[each.key].vm_id,
  ]

  connection {
    type        = "ssh"
    host        = split("/", local.radius_vms[each.key].management_address)[0]
    user        = local.radius_vms[each.key].config.ssh_username
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = ["install -d -m 0700 /tmp/tofu-radius-${self.id}"]
  }

  provisioner "file" {
    content     = each.value
    destination = "/tmp/tofu-radius-${self.id}/deploy.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "rc=0; sudo -n bash /tmp/tofu-radius-${self.id}/deploy.sh || rc=$?; rm -rf /tmp/tofu-radius-${self.id}; exit $rc",
    ]
  }
}

output "radius_servers" {
  description = "FreeRADIUS servers: the address RADIUS clients send to (lylat-app NIC), auth 1812/udp, accounting 1813/udp."
  value = !local.radius_enabled ? {} : {
    for name, vm in local.radius_vms : name => one([for nic in vm.network_devices : split("/", nic.ipv4_address)[0] if nic.ipv4_address != null && nic.ipv4_gateway != null])
  }
}
