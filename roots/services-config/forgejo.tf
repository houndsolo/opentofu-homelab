# Forgejo on the role = "forgejo" VMs (git01/git02): https://git.lylat.space and git over SSH on :2222.
# Forgejo isn't active/active-ready (unlike Gitea it has no [global_lock], so every node would run every cron
# task), so the pair is ACTIVE/PASSIVE: the first VM by name (git01) is the primary and serves everything; the
# others run Forgejo too, as hot standbys with every cron task off, and the proxy pair sends them traffic only
# while the primary doesn't answer (proxy.tf active_passive: nginx "backup" servers, for HTTPS and :2222). No
# VIP and no keepalived here: the proxy pair already has one.
#
# Shared state, so the standby can take over at once:
#   Postgres   Patroni via postgres-vip, database "forgejo" (role + pg_hba from monitoring-config
#              postgres_app_roles, password app_db_passwords["forgejo"]), TLS without certificate checks.
#   Valkey     sessions, cache and queues through the Sentinels (redis+sentinel://, master name
#              var.valkey.master_name; the data password goes to the Valkey nodes only).
#   CephFS     /forgejo (client.forgejo, key in forgejo.secret.auto.tfvars) at /var/lib/forgejo, which is
#              /var/lib/gitea inside the container (the rootless image keeps Gitea's paths): repositories, LFS,
#              attachments, avatars, packages, the SSH server's host keys (the same on every node) and custom/.
#              app.ini is local (/etc/forgejo = /etc/gitea in the container), per node (the cron block differs).
#   Indexers   issues: "db" (bleve can't be shared); code search: off (needs Elasticsearch).
#
# Install: the first deploy on the primary (the canary) starts Forgejo against the empty database (Forgejo
# creates its tables) and creates the admin user when none exists; the standby starts afterwards.
# Upgrades (new image tag): the canary migrates the database first, the standby then finds it migrated.
variable "forgejo" {
  description = "Forgejo (active/passive on the role = \"forgejo\" VMs): public name, database, CephFS, Valkey databases, admin. null = don't deploy."
  type = object({
    domain   = optional(string, "git.lylat.space") # = the proxy host (var.proxy.hosts.git)
    app_name = optional(string, "lylat git")
    ssh_port = optional(number, 2222) # port in clone URLs: the proxy's TCP forward (var.proxy.tcp git-ssh)
    database = optional(object({
      host = optional(string, "10.56.14.104") # Patroni VIP (lylat-data)
      port = optional(number, 5432)
      name = optional(string, "forgejo")
      user = optional(string, "forgejo")
    }), {})
    cephfs = optional(object({
      monitors = optional(list(string), ["10.27.0.12", "10.27.0.13", "10.27.0.14", "10.27.0.17"]) # macbeth, titania, zoness, venom
      fs       = optional(string, "cephfs")
      path     = optional(string, "/forgejo")
      client   = optional(string, "forgejo")
    }), {})
    # Valkey databases: NetBox uses 0/1, Nextcloud 2/3.
    session_dbindex = optional(number, 4)
    cache_dbindex   = optional(number, 5)
    queue_dbindex   = optional(number, 6)
    admin_user      = optional(string, "gitadmin") # "admin" is reserved; password: output forgejo_admin_password
    admin_email     = optional(string, "gitadmin@lylat.space")
    # Accounts are created by the admin (or a later SSO), not by self-registration.
    disable_registration = optional(bool, true)
    require_signin_view  = optional(bool, false)
  })
  default = {}

  validation {
    condition = var.forgejo == null || try(
      length(distinct([var.forgejo.session_dbindex, var.forgejo.cache_dbindex, var.forgejo.queue_dbindex])) == 3 &&
      alltrue([for i in [var.forgejo.session_dbindex, var.forgejo.cache_dbindex, var.forgejo.queue_dbindex] : i >= 4 && i <= 15]) &&
      var.forgejo.admin_user != "admin", false
    )
    error_message = "forgejo: the three Valkey dbindexes differ and are 4..15 (0-3 belong to NetBox and Nextcloud); admin_user can't be \"admin\" (reserved)."
  }
}

variable "forgejo_cephfs_key" {
  description = "CephFS key of client.forgejo (forgejo.secret.auto.tfvars, git-ignored). null = Forgejo isn't deployed (the nodes need the shared repositories)."
  type        = string
  sensitive   = true
  default     = null
}

# Generated once, kept in this root's (encrypted) state; the same values on every node.
resource "random_password" "forgejo_admin" {
  count   = local.forgejo_enabled ? 1 : 0
  length  = 32
  special = false
}

resource "random_password" "forgejo_secret_key" {
  count   = local.forgejo_enabled ? 1 : 0
  length  = 64
  special = false
}

resource "random_password" "forgejo_internal_token" {
  count   = local.forgejo_enabled ? 1 : 0
  length  = 105
  special = false
}

# JWT secrets: 32 bytes, base64 (URL alphabet, no padding).
resource "random_bytes" "forgejo_jwt" {
  for_each = local.forgejo_enabled ? toset(["lfs", "oauth2"]) : toset([])
  length   = 32
}

locals {
  forgejo_vms   = { for name, vm in var.vms : name => vm if vm.owner == "services-vms" && vm.role == "forgejo" }
  forgejo_names = sort(keys(local.forgejo_vms))
  # The primary = the first VM by name, as in proxy.tf's active_passive upstreams (the rest are nginx backups).
  forgejo_primary = try(local.forgejo_names[0], null)
  # Needs its database password, the Valkey trio and the shared CephFS directory.
  forgejo_enabled = (var.forgejo != null && length(local.forgejo_vms) > 0 && local.valkey_enabled &&
  nonsensitive(contains(keys(var.app_db_passwords), "forgejo")) && nonsensitive(var.forgejo_cephfs_key != null))

  # network_devices[i] is eth<i+1>: Forgejo is published on the lylat-app NIC (the one with the gateway).
  forgejo_listen = !local.forgejo_enabled ? {} : {
    for name in keys(local.forgejo_vms) : name => one(local.vm_gateway_addresses[name])
  }

  forgejo_jwt = { for k, b in random_bytes.forgejo_jwt : k => replace(replace(trimsuffix(trimsuffix(b.base64, "="), "="), "+", "-"), "/", "_") }

  # Every cron task that runs by default (Forgejo config cheat sheet, "Basic cron tasks"): all switched off
  # on a standby, so scheduled work runs once, on the primary.
  forgejo_cron_tasks = [
    "archive_cleanup", "update_mirrors", "repo_health_check", "check_repo_stats", "cleanup_hook_task_table",
    "cleanup_packages", "update_migration_poster_id", "sync_external_users", "cleanup_actions", "update_checker",
  ]

  # app.ini per node (0600, uid 1000 = git in the image): identical except the standby's cron block.
  forgejo_app_ini = !local.forgejo_enabled ? {} : {
    for name in keys(local.forgejo_vms) : name => templatefile("${path.module}/templates/forgejo-app.ini.tftpl", {
      app_name             = var.forgejo.app_name
      domain               = var.forgejo.domain
      ssh_port             = var.forgejo.ssh_port
      db_host              = var.forgejo.database.host
      db_port              = var.forgejo.database.port
      db_name              = var.forgejo.database.name
      db_user              = var.forgejo.database.user
      db_password          = var.app_db_passwords["forgejo"]
      valkey               = "redis+sentinel://:${random_password.valkey[0].result}@${join(",", local.valkey_sentinels)}"
      master_name          = var.valkey.master_name
      session_db           = var.forgejo.session_dbindex
      cache_db             = var.forgejo.cache_dbindex
      queue_db             = var.forgejo.queue_dbindex
      secret_key           = random_password.forgejo_secret_key[0].result
      internal_token       = random_password.forgejo_internal_token[0].result
      lfs_jwt_secret       = local.forgejo_jwt["lfs"]
      oauth2_jwt_secret    = local.forgejo_jwt["oauth2"]
      trusted_proxies      = join(",", sort(flatten([for vm in values(local.proxy_vms) : [for nic in vm.network_devices : "${split("/", nic.ipv4_address)[0]}/32" if nic.ipv4_address != null]])))
      disable_registration = var.forgejo.disable_registration
      require_signin_view  = var.forgejo.require_signin_view
      standby              = name != local.forgejo_primary
      cron_tasks           = local.forgejo_cron_tasks
    })
  }

  forgejo_health = { for name, a in local.forgejo_listen : name => "curl -sf --max-time 5 'http://${a}:3000/api/healthz'" }
  forgejo_cli    = "podman exec -u 1000 forgejo forgejo -c /etc/gitea/app.ini"

  # The deploy (modules/services/quadlet-deploy), per node: the CephFS mount and the shared directories on it,
  # app.ini, the container. Forgejo checks its own HTTP server (HealthCmd + Notify=healthy); the database,
  # Valkey and storage checks run afterwards (verify: /api/healthz).
  forgejo_files = {
    for name, vm in(!local.forgejo_enabled ? {} : local.forgejo_vms) : name => concat([
      # CephFS /forgejo at /var/lib/forgejo (kernel client; mount.ceph comes with ceph-common).
      { path = "/etc/ceph/${var.forgejo.cephfs.client}.secret", mode = "0600", content = var.forgejo_cephfs_key },
      { path = "/etc/systemd/system/var-lib-forgejo.mount", units = ["var-lib-forgejo.mount"], content = templatefile("${path.module}/templates/forgejo-cephfs.mount.tftpl", {
        what    = "${join(",", [for m in var.forgejo.cephfs.monitors : "${m}:6789"])}:${var.forgejo.cephfs.path}"
        options = "name=${var.forgejo.cephfs.client},secretfile=/etc/ceph/${var.forgejo.cephfs.client}.secret,mds_namespace=${var.forgejo.cephfs.fs},noatime,_netdev"
      }) },
      { path = "/etc/containers/systemd/forgejo.container", units = ["forgejo"], content = templatefile("${path.module}/templates/forgejo.container.tftpl", {
        image   = local.container_images.forgejo
        listen  = local.forgejo_listen[name]
        domain  = var.forgejo.domain
        standby = name != local.forgejo_primary
      }) },
      { path = "/etc/forgejo/app.ini", mode = "0600", owner = "1000:1000", units = ["forgejo"], restart = true, content = local.forgejo_app_ini[name] },
      ], [for f in [
        # Admin user (primary only, created when Forgejo has no admin yet): the password goes in through an
        # env file, never the command line on the host; never installed.
        { path = "/deploy/admin.env", stage_only = true, content = "FORGEJO_ADMIN_PASS=${random_password.forgejo_admin[0].result}\n" },
    ] : f if name == local.forgejo_primary])
  }

  # Canary first: the primary creates (first deploy) or migrates (new version) the database.
  forgejo_canary = { for name, f in local.forgejo_files : name => f if name == local.forgejo_primary }
  forgejo_rest   = { for name, f in local.forgejo_files : name => f if name != local.forgejo_primary }
}

module "forgejo" {
  source   = "../../modules/services/quadlet-deploy"
  for_each = local.forgejo_files

  name     = "forgejo"
  host     = each.key
  files    = each.value
  units    = ["var-lib-forgejo.mount", "forgejo"]
  images   = [local.container_images.forgejo]
  packages = ["ceph-common", "curl"]
  dirs = [
    { path = "/var/lib/forgejo" },
    { path = "/etc/forgejo", mode = "0700", owner = "1000:1000" },
  ]
  post_install = [
    "systemctl enable --quiet var-lib-forgejo.mount",
    "systemctl start var-lib-forgejo.mount",
    "mountpoint -q /var/lib/forgejo",
    # The image runs as git (uid/gid 1000); the first node creates the shared directories.
    "chown 1000:1000 /var/lib/forgejo && chmod 0750 /var/lib/forgejo",
  ]
  verify = concat([
    # Database, cache (Valkey) and storage reachable from this node.
    "retry sh -c \"${local.forgejo_health[each.key]} | grep -q '\\\"status\\\": *\\\"pass\\\"'\"",
    ], each.key == local.forgejo_primary ? [
    # First deploy (primary only): the admin user, when Forgejo has none yet.
    "if [ -z \"$(${local.forgejo_cli} admin user list --admin | tail -n +2)\" ]; then podman exec -u 1000 --env-file \"$stage/deploy/admin.env\" forgejo sh -c 'forgejo -c /etc/gitea/app.ini admin user create --admin --username ${var.forgejo.admin_user} --email ${var.forgejo.admin_email} --password \"$FORGEJO_ADMIN_PASS\" --must-change-password=false' && echo 'forgejo: admin user ${var.forgejo.admin_user} created'; fi",
    ] : [], [
    # The SSH server answers with an SSH banner.
    "retry sh -c \"timeout 5 bash -c 'exec 3<>/dev/tcp/${local.forgejo_listen[each.key]}/2222; head -c 4 <&3' | grep -q SSH\"",
  ])
}

resource "terraform_data" "forgejo_canary" {
  for_each   = local.forgejo_canary
  depends_on = [terraform_data.valkey_canary, terraform_data.valkey]

  triggers_replace = [
    sha256(module.forgejo[each.key].script),
    local.forgejo_vms[each.key].management_address,
    local.forgejo_vms[each.key].vm_id,
  ]

  connection {
    type        = "ssh"
    host        = split("/", local.forgejo_vms[each.key].management_address)[0]
    user        = local.forgejo_vms[each.key].config.ssh_username
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = ["install -d -m 0700 /tmp/tofu-forgejo-${self.id}"]
  }

  provisioner "file" {
    content     = module.forgejo[each.key].script
    destination = "/tmp/tofu-forgejo-${self.id}/deploy.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "rc=0; sudo -n bash /tmp/tofu-forgejo-${self.id}/deploy.sh || rc=$?; rm -rf /tmp/tofu-forgejo-${self.id}; exit $rc",
    ]
  }
}

resource "terraform_data" "forgejo" {
  for_each   = local.forgejo_rest
  depends_on = [terraform_data.forgejo_canary]

  triggers_replace = [
    sha256(module.forgejo[each.key].script),
    local.forgejo_vms[each.key].management_address,
    local.forgejo_vms[each.key].vm_id,
  ]

  connection {
    type        = "ssh"
    host        = split("/", local.forgejo_vms[each.key].management_address)[0]
    user        = local.forgejo_vms[each.key].config.ssh_username
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = ["install -d -m 0700 /tmp/tofu-forgejo-${self.id}"]
  }

  provisioner "file" {
    content     = module.forgejo[each.key].script
    destination = "/tmp/tofu-forgejo-${self.id}/deploy.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "rc=0; sudo -n bash /tmp/tofu-forgejo-${self.id}/deploy.sh || rc=$?; rm -rf /tmp/tofu-forgejo-${self.id}; exit $rc",
    ]
  }
}

output "forgejo_url" {
  description = "Forgejo: the public URLs and each node's own address (plain HTTP, for checks)."
  value = !local.forgejo_enabled ? {} : merge(
    {
      public  = "https://${var.forgejo.domain}/ (admin user ${var.forgejo.admin_user}; password: tofu output -raw forgejo_admin_password)"
      ssh     = "ssh://git@${var.forgejo.domain}:${var.forgejo.ssh_port}/<owner>/<repo>.git"
      primary = local.forgejo_primary
    },
    { for name, a in local.forgejo_listen : name => "http://${a}:3000/api/healthz" },
  )
}

output "forgejo_admin_password" {
  description = "Initial password of the Forgejo admin user (set by the first deploy only; changing it in Forgejo doesn't update this)."
  value       = local.forgejo_enabled ? random_password.forgejo_admin[0].result : null
  sensitive   = true
}
