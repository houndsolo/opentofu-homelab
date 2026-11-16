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
# Deliberately NOT here: RADIUS users/groups and the RADIUS clients (devices) with their shared secrets live in
# roots/radius (encrypted state); this root mounts /etc/radius/clients.conf and only seeds the image's default
# (localhost, secret testing123) when it's missing. No EAP certificates yet.
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

  # The deploy (modules/services/quadlet-deploy): host config and the unit, checked with the image (-C) before
  # anything is installed; the schema (canary) before the restart; afterwards the health probes
  # (templates/radius-db.sh.tftpl, unpacked with the pgpass for the deploy only). Health needs the localhost
  # client from roots/radius' clients.conf and the database, so it is a deploy check, not a unit health check.
  radius_files = {
    for name, vm in(!local.radius_enabled ? {} : local.radius_vms) : name => [
      { path = "/etc/containers/systemd/radius.container", units = ["radius"], content = templatefile("${path.module}/templates/radius.container.tftpl", {
        image = local.container_images.freeradius
      }) },
      # 0644 inside the 0700 dir: freeradius drops to its own user (freerad) in the container after start.
      { path = "/etc/radius/sql", units = ["radius"], content = local.radius_sql },
      { path = "/etc/radius/radius.env", mode = "0600", units = ["radius"], restart = true, content = "RADIUS_DB_PASSWORD=${var.app_db_passwords["radius"]}\n" },
      { path = "/deploy/pgpass", stage_only = true, content = "${var.radius.database.host}:${var.radius.database.port}:${var.radius.database.name}:${var.radius.database.user}:${var.app_db_passwords["radius"]}\n" },
      { path = "/deploy/radius-db.sh", stage_only = true, content = templatefile("${path.module}/templates/radius-db.sh.tftpl", {
        image   = local.container_images.freeradius
        canary  = name == local.radius_names[0]
        db_host = var.radius.database.host
        db_port = var.radius.database.port
        db_name = var.radius.database.name
        db_user = var.radius.database.user
      }) },
    ]
  }

  # Canary first: the first VM by name loads the schema before the other server deploys.
  radius_canary = { for name, f in local.radius_files : name => f if name == local.radius_names[0] }
  radius_rest   = { for name, f in local.radius_files : name => f if name != local.radius_names[0] }
}

module "radius" {
  source   = "../../modules/services/quadlet-deploy"
  for_each = local.radius_files

  name     = "radius"
  host     = each.key
  files    = each.value
  units    = ["radius"]
  images   = [local.container_images.freeradius]
  packages = ["postgresql-client"]
  dirs     = [{ path = "/etc/radius", mode = "0700" }]
  checks = [
    # clients.conf belongs to roots/radius (devices + secrets); until it exists, the image's own (localhost only).
    "if [ -s /etc/radius/clients.conf ]; then cp /etc/radius/clients.conf \"$stage/deploy/clients.conf\"; else podman run --rm --entrypoint cat '${local.container_images.freeradius}' /etc/freeradius/clients.conf > \"$stage/deploy/clients.conf\"; fi",
    "podman run --rm --network none --env-file \"$stage/etc/radius/radius.env\" -v \"$stage/etc/radius/sql:/etc/freeradius/mods-enabled/sql:ro\" -v \"$stage/deploy/clients.conf:/etc/freeradius/clients.conf:ro\" '${local.container_images.freeradius}' -C -l stdout > \"$stage/deploy/check.log\" 2>&1 || { tail -30 \"$stage/deploy/check.log\" >&2; echo 'freeradius config check failed' >&2; exit 1; }",
  ]
  post_install = [
    # Seed clients.conf once so the mount exists before roots/radius' first apply; never overwritten here.
    "[ -s /etc/radius/clients.conf ] || { install -m 0644 \"$stage/deploy/clients.conf\" /etc/radius/clients.conf; echo 'seeded /etc/radius/clients.conf from the image (roots/radius manages it from now on)'; }",
    "bash \"$stage/deploy/radius-db.sh\" schema",
  ]
  verify = ["bash \"$stage/deploy/radius-db.sh\" probe"]
}

resource "terraform_data" "radius_canary" {
  for_each = local.radius_canary

  triggers_replace = [
    sha256(module.radius[each.key].script),
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
    content     = module.radius[each.key].script
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
    sha256(module.radius[each.key].script),
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
    content     = module.radius[each.key].script
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
