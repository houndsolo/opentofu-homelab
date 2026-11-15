# Nextcloud on the role = "nextcloud" VMs (nc01-03), active/active: every node serves, the reverse proxy
# (proxy.tf, host "nextcloud") spreads requests over the nodes' own lylat-app addresses. No VIP and no
# keepalived here: the proxy pair already has one, and nginx there skips a node that stops answering.
#
# Per node, one Podman Quadlet pod (shared localhost, port 80 published on the lylat-app address):
#   nextcloud-app      the official nextcloud:<version>-fpm image (php-fpm :9000 inside the pod)
#   nextcloud-web      nginx (the proxy's pinned image) serving static files, PHP to 127.0.0.1:9000
#   nextcloud-haproxy  127.0.0.1:6379 -> the current Valkey primary, for PHP sessions only (see below)
#
# Shared state, so any node can serve any request:
#   Postgres   Patroni via postgres-vip, database "nextcloud" (role + pg_hba from monitoring-config,
#              password in app_db_passwords), TLS without certificate checks (pgsql_ssl mode=require).
#   CephFS     /nextcloud (client.nextcloud, key in nextcloud.secret.auto.tfvars) at /var/lib/nextcloud:
#              config/ (one config.php for all nodes: instanceid, secret, passwordsalt, DB), data/,
#              custom_apps/ (app-store installs reach every node) and themes/. The code itself
#              (/var/www/html) is local per node: the image's entrypoint copies it from the image.
#   Valkey     file locking + distributed cache through Nextcloud's KeyValueCache (34.0.2+), which asks
#              the Sentinels for the primary itself (memcache.kvstore.sentinel, dbindex 2). predis
#              authenticates with HELLO AUTH default <pw>, which the Sentinels' nopass default user
#              accepts, so the Sentinels stay passwordless (tested 2026-11-15, vault nextcloud-ha-plan).
#   Sessions   PHP's own session handler (phpredis), which can't follow Sentinel: it talks to the local
#              HAProxy, which health-checks the trio for role:master + a connected replica (= the primary
#              Sentinel chose). var.nextcloud.sessions = "local" switches to per-node session files
#              instead (then the proxy host must be sticky; how to switch: vault nextcloud-ha-plan).
#
# Install: the first deploy on the first node by name (the canary) runs occ maintenance:install when the
# shared config says Nextcloud isn't installed yet; the other nodes only start once that succeeded.
# Upgrades (new image tag): the canary's entrypoint runs occ upgrade, the others then find the database
# already upgraded. One major version at a time (the entrypoint refuses bigger jumps).
# Background jobs: cron.php from a systemd timer on var.nextcloud.cron_node only (the default: the
# first node). That node down = background jobs wait; nothing user-facing breaks for hours.
variable "nextcloud" {
  description = "Nextcloud (active/active on the role = \"nextcloud\" VMs): public name, database, CephFS, Valkey databases, PHP sizing. null = don't deploy."
  type = object({
    domain = optional(string, "nextcloud.lylat.space") # = the proxy host (var.proxy.hosts.nextcloud)
    database = optional(object({
      host = optional(string, "10.56.14.104") # Patroni VIP (lylat-data)
      port = optional(number, 5432)
      name = optional(string, "nextcloud")
      user = optional(string, "nextcloud")
    }), {})
    admin_user = optional(string, "admin") # password: random_password.nextcloud_admin (output nextcloud_admin_password)
    cephfs = optional(object({
      monitors = optional(list(string), ["10.27.0.12", "10.27.0.13", "10.27.0.14", "10.27.0.17"]) # macbeth, titania, zoness, venom
      fs       = optional(string, "cephfs")
      path     = optional(string, "/nextcloud")
      client   = optional(string, "nextcloud")
    }), {})
    port = optional(number, 80) # nginx in the pod, published on the node's lylat-app address
    # Valkey databases: NetBox uses 0 (tasks) and 1 (cache).
    cache_dbindex   = optional(number, 2) # file locking + distributed cache (KeyValueCache via Sentinel)
    session_dbindex = optional(number, 3) # PHP sessions (phpredis via the local HAProxy)
    # "valkey": sessions shared through Valkey (any node serves any request; HAProxy in the pod).
    # "local": session files per node (no HAProxy); the proxy host must then be sticky, or users bounce
    # back to the login page. Switching logs every browser out once (sync/mobile clients don't notice).
    sessions = optional(string, "valkey")
    php = optional(object({
      memory_limit = optional(string, "1G")
      upload_limit = optional(string, "16G")  # also nginx client_max_body_size in the pod
      max_children = optional(number, 16)     # php-fpm workers per node (~100-200 MB each in practice)
      apcu_shm     = optional(string, "128M") # APCu local cache per node
    }), {})
    cron_node                = optional(string)    # VM that runs cron.php; null = the first node by name
    maintenance_window_start = optional(number, 6) # UTC hour: heavy daily jobs run in the 4 h after it (01:00 EST)
    phone_region             = optional(string, "US")
  })
  default = {}

  validation {
    condition = var.nextcloud == null || try(
      contains(["valkey", "local"], var.nextcloud.sessions) &&
      var.nextcloud.cache_dbindex != var.nextcloud.session_dbindex &&
      !contains([0, 1], var.nextcloud.cache_dbindex) && !contains([0, 1], var.nextcloud.session_dbindex) &&
      var.nextcloud.maintenance_window_start >= 0 && var.nextcloud.maintenance_window_start <= 23 &&
      var.nextcloud.php.max_children >= 2, false
    )
    error_message = "nextcloud: sessions is \"valkey\" or \"local\"; cache_dbindex and session_dbindex differ and aren't NetBox's 0/1; maintenance_window_start is 0..23; php.max_children >= 2."
  }
}

variable "nextcloud_cephfs_key" {
  description = "CephFS key of client.nextcloud (nextcloud.secret.auto.tfvars, git-ignored). null = Nextcloud isn't deployed (three nodes need the shared config/data)."
  type        = string
  sensitive   = true
  default     = null
}

resource "random_password" "nextcloud_admin" {
  count   = local.nextcloud_enabled ? 1 : 0
  length  = 32
  special = false
}

locals {
  nextcloud_vms   = { for name, vm in var.vms : name => vm if vm.owner == "services-vms" && vm.role == "nextcloud" }
  nextcloud_names = sort(keys(local.nextcloud_vms))
  # Needs its database password, the Valkey trio and the shared CephFS directory.
  nextcloud_enabled = (var.nextcloud != null && length(local.nextcloud_vms) > 0 && local.valkey_enabled &&
  nonsensitive(contains(keys(var.app_db_passwords), "nextcloud")) && nonsensitive(var.nextcloud_cephfs_key != null))
  nextcloud_shared_sessions = local.nextcloud_enabled && try(var.nextcloud.sessions, "") == "valkey"
  nextcloud_cron_node       = !local.nextcloud_enabled ? null : coalesce(var.nextcloud.cron_node, local.nextcloud_names[0])

  # network_devices[i] is eth<i+1>: nginx is published on the lylat-app NIC (the one with the gateway).
  nextcloud_listen = !local.nextcloud_enabled ? {} : {
    for name, vm in local.nextcloud_vms : name => one([for nic in vm.network_devices : split("/", nic.ipv4_address)[0] if nic.ipv4_address != null && nic.ipv4_gateway != null])
  }

  # One config file for every node, on the shared config dir: Nextcloud merges *.config.php over the
  # config.php the installer wrote, and keys set here can't be changed with occ (tofu owns them).
  nextcloud_config_php = !local.nextcloud_enabled ? "" : templatefile("${path.module}/templates/nextcloud.config.php.tftpl", {
    domain          = var.nextcloud.domain
    trusted_proxies = sort([for n in values(local.proxy_nics) : n.service.address])
    sentinels       = [for name in local.valkey_names : local.valkey_backend[name]]
    master_name     = var.valkey.master_name
    valkey_password = random_password.valkey[0].result
    cache_dbindex   = var.nextcloud.cache_dbindex
    maintenance     = var.nextcloud.maintenance_window_start
    phone_region    = var.nextcloud.phone_region
  })

  nextcloud_php_ini = !local.nextcloud_enabled ? "" : templatefile("${path.module}/templates/nextcloud-php.ini.tftpl", {
    php             = var.nextcloud.php
    shared_sessions = local.nextcloud_shared_sessions
    valkey_password = random_password.valkey[0].result
    session_dbindex = var.nextcloud.session_dbindex
  })

  nextcloud_script = !local.nextcloud_enabled ? {} : {
    for name, vm in local.nextcloud_vms : name => templatefile("${path.module}/templates/nextcloud-deploy.sh.tftpl", {
      app_image       = local.container_images.nextcloud
      web_image       = local.container_images.nginx
      haproxy_image   = local.container_images.haproxy
      listen          = local.nextcloud_listen[name]
      port            = var.nextcloud.port
      domain          = var.nextcloud.domain
      install_node    = name == local.nextcloud_names[0]
      cron            = name == local.nextcloud_cron_node
      shared_sessions = local.nextcloud_shared_sessions
      cephfs_client   = var.nextcloud.cephfs.client
      # base64 so secrets never appear in the script as plain text (they are still in tofu's state).
      cephfs_key_b64 = base64encode(var.nextcloud_cephfs_key)
      mount_b64 = base64encode(templatefile("${path.module}/templates/nextcloud-cephfs.mount.tftpl", {
        what    = "${join(",", [for m in var.nextcloud.cephfs.monitors : "${m}:6789"])}:${var.nextcloud.cephfs.path}"
        options = "name=${var.nextcloud.cephfs.client},secretfile=/etc/ceph/${var.nextcloud.cephfs.client}.secret,mds_namespace=${var.nextcloud.cephfs.fs},noatime,_netdev"
      }))
      config_b64 = base64encode(local.nextcloud_config_php)
      php_b64    = base64encode(local.nextcloud_php_ini)
      fpm_b64 = base64encode(templatefile("${path.module}/templates/nextcloud-fpm.conf.tftpl", {
        max_children = var.nextcloud.php.max_children
      }))
      nginx_b64 = base64encode(templatefile("${path.module}/templates/nextcloud-nginx.conf.tftpl", {
        upload_limit = var.nextcloud.php.upload_limit
      }))
      haproxy_b64 = !local.nextcloud_shared_sessions ? "" : base64encode(templatefile("${path.module}/templates/nextcloud-haproxy.cfg.tftpl", {
        servers = { for n in local.valkey_names : n => local.valkey_backend[n] }
      }))
      haproxy_env_b64 = !local.nextcloud_shared_sessions ? "" : base64encode("VALKEY_PASSWORD=${random_password.valkey[0].result}\n")
      install_env_b64 = base64encode(join("", [for k, v in {
        NC_DB_HOST    = "${var.nextcloud.database.host}:${var.nextcloud.database.port}"
        NC_DB_NAME    = var.nextcloud.database.name
        NC_DB_USER    = var.nextcloud.database.user
        NC_DB_PASS    = var.app_db_passwords["nextcloud"]
        NC_ADMIN_USER = var.nextcloud.admin_user
        NC_ADMIN_PASS = random_password.nextcloud_admin[0].result
      } : "${k}=${v}\n"]))
      pod_b64 = base64encode(templatefile("${path.module}/templates/nextcloud.pod.tftpl", {
        listen = local.nextcloud_listen[name]
        port   = var.nextcloud.port
      }))
      app_b64 = base64encode(templatefile("${path.module}/templates/nextcloud-app.container.tftpl", {
        image        = local.container_images.nextcloud
        memory_limit = var.nextcloud.php.memory_limit
        upload_limit = var.nextcloud.php.upload_limit
      }))
      web_b64 = base64encode(templatefile("${path.module}/templates/nextcloud-web.container.tftpl", {
        image = local.container_images.nginx
      }))
      haproxy_unit_b64 = !local.nextcloud_shared_sessions ? "" : base64encode(templatefile("${path.module}/templates/nextcloud-haproxy.container.tftpl", {
        image = local.container_images.haproxy
      }))
      cron_service_b64 = base64encode(file("${path.module}/templates/nextcloud-cron.service"))
      cron_timer_b64   = base64encode(file("${path.module}/templates/nextcloud-cron.timer"))
    })
  }

  # Canary first: the first VM by name installs (first deploy) or upgrades (new major) before the rest.
  nextcloud_canary = { for name, s in local.nextcloud_script : name => s if name == local.nextcloud_names[0] }
  nextcloud_rest   = { for name, s in local.nextcloud_script : name => s if name != local.nextcloud_names[0] }
}

check "nextcloud_cron_node" {
  assert {
    condition     = var.nextcloud == null || try(var.nextcloud.cron_node, null) == null || contains(local.nextcloud_names, try(var.nextcloud.cron_node, ""))
    error_message = "nextcloud.cron_node must be one of the role = \"nextcloud\" VMs (${join(", ", local.nextcloud_names)})."
  }
}

resource "terraform_data" "nextcloud_canary" {
  for_each   = local.nextcloud_canary
  depends_on = [terraform_data.valkey_canary, terraform_data.valkey]

  triggers_replace = [
    sha256(each.value),
    local.nextcloud_vms[each.key].management_address,
    local.nextcloud_vms[each.key].vm_id,
  ]

  connection {
    type        = "ssh"
    host        = split("/", local.nextcloud_vms[each.key].management_address)[0]
    user        = local.nextcloud_vms[each.key].config.ssh_username
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = ["install -d -m 0700 /tmp/tofu-nextcloud-${self.id}"]
  }

  provisioner "file" {
    content     = each.value
    destination = "/tmp/tofu-nextcloud-${self.id}/deploy.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "rc=0; sudo -n bash /tmp/tofu-nextcloud-${self.id}/deploy.sh || rc=$?; rm -rf /tmp/tofu-nextcloud-${self.id}; exit $rc",
    ]
  }
}

resource "terraform_data" "nextcloud" {
  for_each   = local.nextcloud_rest
  depends_on = [terraform_data.nextcloud_canary]

  triggers_replace = [
    sha256(each.value),
    local.nextcloud_vms[each.key].management_address,
    local.nextcloud_vms[each.key].vm_id,
  ]

  connection {
    type        = "ssh"
    host        = split("/", local.nextcloud_vms[each.key].management_address)[0]
    user        = local.nextcloud_vms[each.key].config.ssh_username
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = ["install -d -m 0700 /tmp/tofu-nextcloud-${self.id}"]
  }

  provisioner "file" {
    content     = each.value
    destination = "/tmp/tofu-nextcloud-${self.id}/deploy.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "rc=0; sudo -n bash /tmp/tofu-nextcloud-${self.id}/deploy.sh || rc=$?; rm -rf /tmp/tofu-nextcloud-${self.id}; exit $rc",
    ]
  }
}

output "nextcloud_url" {
  description = "Nextcloud: the public URL and each node's own address (plain HTTP, for checks)."
  value = !local.nextcloud_enabled ? {} : merge(
    { public = "https://${var.nextcloud.domain}/ (admin user ${var.nextcloud.admin_user}; password: tofu output -raw nextcloud_admin_password)" },
    { for name, a in local.nextcloud_listen : name => "http://${a}:${var.nextcloud.port}/status.php" },
  )
}

output "nextcloud_admin_password" {
  description = "Initial password of the Nextcloud admin user (set by the first install only; changing it in Nextcloud doesn't update this)."
  value       = local.nextcloud_enabled ? random_password.nextcloud_admin[0].result : null
  sensitive   = true
}
