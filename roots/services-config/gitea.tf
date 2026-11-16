# Gitea on the role = "gitea" VMs (git01/git02), active/active as in Gitea's documented HA layout
# (docs.gitea.com/enterprise/installation/high-availability; every setting it uses exists in the open-source
# release too): every node serves, the reverse proxy (proxy.tf) spreads https://git.lylat.space/ over the
# nodes' own lylat-app addresses and forwards git over SSH (TCP :2222, var.proxy.tcp) the same way. No VIP and
# no keepalived here: the proxy pair already has one, and nginx there skips a node that stops answering.
#
# Shared state, so any node can serve any request:
#   Postgres   Patroni via postgres-vip, database "gitea" (role + pg_hba from monitoring-config postgres_app_roles,
#              password app_db_passwords["gitea"]), TLS without certificate checks (SSL_MODE = require).
#   Valkey     sessions, cache, queues and the global lock through the Sentinels (redis+sentinel://, master
#              name var.valkey.master_name; the data password is sent to the Valkey nodes only, the Sentinels
#              stay passwordless). The global lock makes each cron task run on one node at a time.
#   CephFS     /gitea (client.gitea, key in gitea.secret.auto.tfvars) at /var/lib/gitea: repositories, LFS,
#              attachments, avatars, packages, the built-in SSH server's host keys (the same keys on every node)
#              and custom/. app.ini is local (/etc/gitea) and identical on every node.
#   Indexers   issues: "db" (bleve can't be shared between nodes); code search: off (needs Elasticsearch).
#
# Install: the first deploy on the first node by name (the canary) starts Gitea against the empty database
# (Gitea creates its tables) and creates the admin user when none exists; the other node starts afterwards.
# Upgrades (new image tag): the canary migrates the database first, the other node then finds it migrated.
variable "gitea" {
  description = "Gitea (active/active on the role = \"gitea\" VMs): public name, database, CephFS, Valkey databases, admin. null = don't deploy."
  type = object({
    domain   = optional(string, "git.lylat.space") # = the proxy host (var.proxy.hosts.git)
    app_name = optional(string, "lylat git")
    ssh_port = optional(number, 2222) # port in clone URLs: the proxy's TCP forward (var.proxy.tcp git-ssh)
    database = optional(object({
      host = optional(string, "10.56.14.104") # Patroni VIP (lylat-data)
      port = optional(number, 5432)
      name = optional(string, "gitea")
      user = optional(string, "gitea")
    }), {})
    cephfs = optional(object({
      monitors = optional(list(string), ["10.27.0.12", "10.27.0.13", "10.27.0.14", "10.27.0.17"]) # macbeth, titania, zoness, venom
      fs       = optional(string, "cephfs")
      path     = optional(string, "/gitea")
      client   = optional(string, "gitea")
    }), {})
    # Valkey databases: NetBox uses 0/1, Nextcloud 2/3.
    session_dbindex = optional(number, 4)
    cache_dbindex   = optional(number, 5)
    queue_dbindex   = optional(number, 6)
    lock_dbindex    = optional(number, 7)
    admin_user      = optional(string, "gitadmin") # "admin" is reserved by Gitea; password: output gitea_admin_password
    admin_email     = optional(string, "gitadmin@lylat.space")
    # Accounts are created by the admin (or a later SSO), not by self-registration.
    disable_registration = optional(bool, true)
    require_signin_view  = optional(bool, false)
  })
  default = {}

  validation {
    condition = var.gitea == null || try(
      length(distinct([var.gitea.session_dbindex, var.gitea.cache_dbindex, var.gitea.queue_dbindex, var.gitea.lock_dbindex])) == 4 &&
      alltrue([for i in [var.gitea.session_dbindex, var.gitea.cache_dbindex, var.gitea.queue_dbindex, var.gitea.lock_dbindex] : i >= 4 && i <= 15]) &&
      var.gitea.admin_user != "admin", false
    )
    error_message = "gitea: the four Valkey dbindexes differ and are 4..15 (0-3 belong to NetBox and Nextcloud); admin_user can't be \"admin\" (reserved by Gitea)."
  }
}

variable "gitea_cephfs_key" {
  description = "CephFS key of client.gitea (gitea.secret.auto.tfvars, git-ignored). null = Gitea isn't deployed (the nodes need the shared repositories)."
  type        = string
  sensitive   = true
  default     = null
}

# Generated once, kept in this root's (encrypted) state; the same values on every node.
resource "random_password" "gitea_admin" {
  count   = local.gitea_enabled ? 1 : 0
  length  = 32
  special = false
}

resource "random_password" "gitea_secret_key" {
  count   = local.gitea_enabled ? 1 : 0
  length  = 64
  special = false
}

resource "random_password" "gitea_internal_token" {
  count   = local.gitea_enabled ? 1 : 0
  length  = 105
  special = false
}

# JWT secrets: Gitea wants 32 bytes, base64 (URL alphabet, no padding).
resource "random_bytes" "gitea_jwt" {
  for_each = local.gitea_enabled ? toset(["lfs", "oauth2"]) : toset([])
  length   = 32
}

locals {
  gitea_vms   = { for name, vm in var.vms : name => vm if vm.owner == "services-vms" && vm.role == "gitea" }
  gitea_names = sort(keys(local.gitea_vms))
  # Needs its database password, the Valkey trio and the shared CephFS directory.
  gitea_enabled = (var.gitea != null && length(local.gitea_vms) > 0 && local.valkey_enabled &&
  nonsensitive(contains(keys(var.app_db_passwords), "gitea")) && nonsensitive(var.gitea_cephfs_key != null))

  # network_devices[i] is eth<i+1>: Gitea is published on the lylat-app NIC (the one with the gateway).
  gitea_listen = !local.gitea_enabled ? {} : {
    for name, vm in local.gitea_vms : name => one([for nic in vm.network_devices : split("/", nic.ipv4_address)[0] if nic.ipv4_address != null && nic.ipv4_gateway != null])
  }

  gitea_jwt = { for k, b in random_bytes.gitea_jwt : k => replace(replace(trimsuffix(trimsuffix(b.base64, "="), "="), "+", "-"), "/", "_") }

  # One app.ini for every node (0600, uid 1000 = git in the image: Gitea may rewrite it, e.g. on upgrades).
  gitea_app_ini = !local.gitea_enabled ? "" : templatefile("${path.module}/templates/gitea-app.ini.tftpl", {
    app_name             = var.gitea.app_name
    domain               = var.gitea.domain
    ssh_port             = var.gitea.ssh_port
    db_host              = var.gitea.database.host
    db_port              = var.gitea.database.port
    db_name              = var.gitea.database.name
    db_user              = var.gitea.database.user
    db_password          = var.app_db_passwords["gitea"]
    valkey               = "redis+sentinel://:${random_password.valkey[0].result}@${join(",", local.valkey_sentinels)}"
    master_name          = var.valkey.master_name
    session_db           = var.gitea.session_dbindex
    cache_db             = var.gitea.cache_dbindex
    queue_db             = var.gitea.queue_dbindex
    lock_db              = var.gitea.lock_dbindex
    secret_key           = random_password.gitea_secret_key[0].result
    internal_token       = random_password.gitea_internal_token[0].result
    lfs_jwt_secret       = local.gitea_jwt["lfs"]
    oauth2_jwt_secret    = local.gitea_jwt["oauth2"]
    trusted_proxies      = join(",", sort(flatten([for vm in values(local.proxy_vms) : [for nic in vm.network_devices : "${split("/", nic.ipv4_address)[0]}/32" if nic.ipv4_address != null]])))
    disable_registration = var.gitea.disable_registration
    require_signin_view  = var.gitea.require_signin_view
  })

  gitea_health = { for name, a in local.gitea_listen : name => "curl -sf --max-time 5 'http://${a}:3000/api/healthz'" }
  gitea_cli    = "podman exec -u 1000 gitea gitea -c /etc/gitea/app.ini"

  # The deploy (modules/services/quadlet-deploy), per node: the CephFS mount and the shared directories on it,
  # app.ini, the container. Gitea checks its own HTTP server (HealthCmd + Notify=healthy); the database,
  # Valkey and storage checks run afterwards (verify: /api/healthz).
  gitea_files = {
    for name, vm in(!local.gitea_enabled ? {} : local.gitea_vms) : name => concat([
      # CephFS /gitea at /var/lib/gitea (kernel client; mount.ceph comes with ceph-common).
      { path = "/etc/ceph/${var.gitea.cephfs.client}.secret", mode = "0600", content = var.gitea_cephfs_key },
      { path = "/etc/systemd/system/var-lib-gitea.mount", units = ["var-lib-gitea.mount"], content = templatefile("${path.module}/templates/gitea-cephfs.mount.tftpl", {
        what    = "${join(",", [for m in var.gitea.cephfs.monitors : "${m}:6789"])}:${var.gitea.cephfs.path}"
        options = "name=${var.gitea.cephfs.client},secretfile=/etc/ceph/${var.gitea.cephfs.client}.secret,mds_namespace=${var.gitea.cephfs.fs},noatime,_netdev"
      }) },
      { path = "/etc/containers/systemd/gitea.container", units = ["gitea"], content = templatefile("${path.module}/templates/gitea.container.tftpl", {
        image  = local.container_images.gitea
        listen = local.gitea_listen[name]
        domain = var.gitea.domain
      }) },
      { path = "/etc/gitea/app.ini", mode = "0600", owner = "1000:1000", units = ["gitea"], restart = true, content = local.gitea_app_ini },
      ], [for f in [
        # Admin user (canary only, created when Gitea has no admin yet): the password goes in through an env
        # file, never the command line on the host; never installed.
        { path = "/deploy/admin.env", stage_only = true, content = "GITEA_ADMIN_PASS=${random_password.gitea_admin[0].result}\n" },
    ] : f if name == local.gitea_names[0]])
  }

  # Canary first: the first VM by name creates (first deploy) or migrates (new version) the database.
  gitea_canary = { for name, f in local.gitea_files : name => f if name == local.gitea_names[0] }
  gitea_rest   = { for name, f in local.gitea_files : name => f if name != local.gitea_names[0] }
}

module "gitea" {
  source   = "../../modules/services/quadlet-deploy"
  for_each = local.gitea_files

  name     = "gitea"
  host     = each.key
  files    = each.value
  units    = ["var-lib-gitea.mount", "gitea"]
  images   = [local.container_images.gitea]
  packages = ["ceph-common", "curl"]
  dirs = [
    { path = "/var/lib/gitea" },
    { path = "/etc/gitea", mode = "0700", owner = "1000:1000" },
  ]
  post_install = [
    "systemctl enable --quiet var-lib-gitea.mount",
    "systemctl start var-lib-gitea.mount",
    "mountpoint -q /var/lib/gitea",
    # The image runs as git (uid/gid 1000); the first node creates the shared directories.
    "chown 1000:1000 /var/lib/gitea && chmod 0750 /var/lib/gitea",
  ]
  verify = concat([
    # Database, cache (Valkey) and storage reachable from this node.
    "retry sh -c \"${local.gitea_health[each.key]} | grep -q '\\\"status\\\": *\\\"pass\\\"'\"",
    ], each.key == local.gitea_names[0] ? [
    # First deploy (canary only): the admin user, when Gitea has none yet.
    "if [ -z \"$(${local.gitea_cli} admin user list --admin | tail -n +2)\" ]; then podman exec -u 1000 --env-file \"$stage/deploy/admin.env\" gitea sh -c 'gitea -c /etc/gitea/app.ini admin user create --admin --username ${var.gitea.admin_user} --email ${var.gitea.admin_email} --password \"$GITEA_ADMIN_PASS\" --must-change-password=false' && echo 'gitea: admin user ${var.gitea.admin_user} created'; fi",
    ] : [], [
    # The SSH server answers with Gitea's banner.
    "retry sh -c \"timeout 5 bash -c 'exec 3<>/dev/tcp/${local.gitea_listen[each.key]}/2222; head -c 4 <&3' | grep -q SSH\"",
  ])
}

resource "terraform_data" "gitea_canary" {
  for_each   = local.gitea_canary
  depends_on = [terraform_data.valkey_canary, terraform_data.valkey]

  triggers_replace = [
    sha256(module.gitea[each.key].script),
    local.gitea_vms[each.key].management_address,
    local.gitea_vms[each.key].vm_id,
  ]

  connection {
    type        = "ssh"
    host        = split("/", local.gitea_vms[each.key].management_address)[0]
    user        = local.gitea_vms[each.key].config.ssh_username
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = ["install -d -m 0700 /tmp/tofu-gitea-${self.id}"]
  }

  provisioner "file" {
    content     = module.gitea[each.key].script
    destination = "/tmp/tofu-gitea-${self.id}/deploy.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "rc=0; sudo -n bash /tmp/tofu-gitea-${self.id}/deploy.sh || rc=$?; rm -rf /tmp/tofu-gitea-${self.id}; exit $rc",
    ]
  }
}

resource "terraform_data" "gitea" {
  for_each   = local.gitea_rest
  depends_on = [terraform_data.gitea_canary]

  triggers_replace = [
    sha256(module.gitea[each.key].script),
    local.gitea_vms[each.key].management_address,
    local.gitea_vms[each.key].vm_id,
  ]

  connection {
    type        = "ssh"
    host        = split("/", local.gitea_vms[each.key].management_address)[0]
    user        = local.gitea_vms[each.key].config.ssh_username
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = ["install -d -m 0700 /tmp/tofu-gitea-${self.id}"]
  }

  provisioner "file" {
    content     = module.gitea[each.key].script
    destination = "/tmp/tofu-gitea-${self.id}/deploy.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "rc=0; sudo -n bash /tmp/tofu-gitea-${self.id}/deploy.sh || rc=$?; rm -rf /tmp/tofu-gitea-${self.id}; exit $rc",
    ]
  }
}

output "gitea_url" {
  description = "Gitea: the public URLs and each node's own address (plain HTTP, for checks)."
  value = !local.gitea_enabled ? {} : merge(
    {
      public = "https://${var.gitea.domain}/ (admin user ${var.gitea.admin_user}; password: tofu output -raw gitea_admin_password)"
      ssh    = "ssh://git@${var.gitea.domain}:${var.gitea.ssh_port}/<owner>/<repo>.git"
    },
    { for name, a in local.gitea_listen : name => "http://${a}:3000/api/healthz" },
  )
}

output "gitea_admin_password" {
  description = "Initial password of the Gitea admin user (set by the first deploy only; changing it in Gitea doesn't update this)."
  value       = local.gitea_enabled ? random_password.gitea_admin[0].result : null
  sensitive   = true
}
