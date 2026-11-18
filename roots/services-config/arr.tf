# Media automation ("arr stack") on the role = "arr" VM (arr01, VM 878, 10.2.7.8 / 10.8.7.8): one Podman pod with
#   Prowlarr  (9696)  indexers, pushed to Sonarr/Radarr
#   Sonarr    (8989)  TV: finds releases, sends them to qBittorrent, imports finished ones into the library
#   Radarr    (7878)  movies: the same for films
#   Bazarr    (6767)  subtitles for what Sonarr/Radarr imported
#   Jellyfin  (8096)  media server (CPU transcoding)
#   Seerr     (5055)  request page (Jellyseerr's successor): users ask for a show/movie, it tells Sonarr/Radarr
# Every UI is https://<app>.lylat.space through the proxy pair (proxy.tf hosts).
#
# Storage: CephFS /media (client.arr, key in arr.secret.auto.tfvars) at /data on the VM and inside the apps:
# /data/torrents (qBittorrent on CT 877 writes there; categories tv-sonarr/radarr) and
# /data/library/{tv,movies,anime,anime-movies} (anime: own Sonarr/Radarr root folders and Jellyfin libraries).
# One mount for both, so an import is a hardlink (instant, no second copy) and seeding keeps working.
# App configs (SQLite) stay on the VM's disk in /var/lib/arr/<app> (SQLite on CephFS is asking for locking
# trouble); the apps write their own nightly backup zips there.
# The download client is NOT here: qBittorrent runs on CT 877 (hand-managed, behind Mullvad WireGuard) and is
# reached at 10.8.7.7 over arr01's own VLAN 8 NIC (the tunnel only answers 10.8/16 and 10.27/16). Its login is entered in
# Sonarr/Radarr by hand (see the vault note Instructions/arr-stack/arr-stack.md).
#
# First deploy: templates/arr-setup.sh wires what can be wired without the owner's secrets (logins, root folders,
# Prowlarr -> Sonarr/Radarr, Bazarr -> Sonarr/Radarr, Jellyfin wizard + libraries), each step once.
variable "arr" {
  description = "arr stack on the role = \"arr\" VM: admin user, timezone, public names. null = don't deploy."
  type = object({
    admin_user = optional(string, "admin") # Sonarr/Radarr/Prowlarr/Bazarr/Jellyfin login; password: output arr_admin_password
    timezone   = optional(string, "America/New_York")
    uid        = optional(number, 11000) # owner of the files on /media (= qBittorrent's PUID on CT 877)
    cephfs = optional(object({
      monitors = optional(list(string), ["10.27.0.12", "10.27.0.13", "10.27.0.14", "10.27.0.17"]) # macbeth, titania, zoness, venom
      fs       = optional(string, "cephfs")
      path     = optional(string, "/media")
      client   = optional(string, "arr")
    }), {})
  })
  default = {}
}

variable "arr_cephfs_key" {
  description = "CephFS key of client.arr (arr.secret.auto.tfvars, git-ignored). null = the arr stack isn't deployed."
  type        = string
  sensitive   = true
  default     = null
}

# Generated once, kept in this root's (encrypted) state.
resource "random_password" "arr_admin" {
  count   = local.arr_enabled ? 1 : 0
  length  = 24
  special = false
}

# Servarr API keys (32 hex chars), pinned through the units' env so the setup script and Prowlarr know them.
resource "random_id" "arr_api_key" {
  for_each    = local.arr_enabled ? toset(["sonarr", "radarr", "prowlarr"]) : toset([])
  byte_length = 16
}

locals {
  arr_vms     = { for name, vm in var.vms : name => vm if vm.owner == "services-vms" && vm.role == "arr" }
  arr_enabled = var.arr != null && length(local.arr_vms) > 0 && nonsensitive(var.arr_cephfs_key != null)

  # network_devices[i] is eth<i+1>: the UIs are published on the NIC with the gateway (VLAN 2, the same
  # VLAN as the proxies' own main NIC, so nginx reaches them without a router; proxy.tf uses that NIC too).
  arr_listen = !local.arr_enabled ? {} : {
    for name, vm in local.arr_vms : name => one([for nic in vm.network_devices : split("/", nic.ipv4_address)[0] if nic.ipv4_address != null && nic.ipv4_gateway != null])
  }

  arr_ports = { prowlarr = 9696, sonarr = 8989, radarr = 7878, bazarr = 6767, jellyfin = 8096, seerr = 5055 }
  arr_key   = { for k, r in random_id.arr_api_key : k => r.hex }

  # Per app: image key, description, user (empty = the image's own, linuxserver images take PUID/PGID),
  # env, volumes, health check.
  arr_lsio_env = local.arr_enabled ? { PUID = var.arr.uid, PGID = var.arr.uid, UMASK = "002", TZ = var.arr.timezone } : {}
  arr_apps = !local.arr_enabled ? {} : {
    prowlarr = {
      description = "Prowlarr: indexer manager for Sonarr and Radarr"
      user        = ""
      env         = merge(local.arr_lsio_env, { PROWLARR__AUTH__APIKEY = local.arr_key["prowlarr"], PROWLARR__AUTH__METHOD = "Forms", PROWLARR__AUTH__REQUIRED = "Enabled" })
      volumes     = ["/var/lib/arr/prowlarr:/config"]
      health      = "curl -fsS -o /dev/null http://127.0.0.1:9696/ping"
    }
    sonarr = {
      description = "Sonarr: TV series (search, download via qBittorrent, import into /data/library/tv)"
      user        = ""
      env         = merge(local.arr_lsio_env, { SONARR__AUTH__APIKEY = local.arr_key["sonarr"], SONARR__AUTH__METHOD = "Forms", SONARR__AUTH__REQUIRED = "Enabled" })
      volumes     = ["/var/lib/arr/sonarr:/config", "/data:/data"]
      health      = "curl -fsS -o /dev/null http://127.0.0.1:8989/ping"
    }
    radarr = {
      description = "Radarr: movies (search, download via qBittorrent, import into /data/library/movies)"
      user        = ""
      env         = merge(local.arr_lsio_env, { RADARR__AUTH__APIKEY = local.arr_key["radarr"], RADARR__AUTH__METHOD = "Forms", RADARR__AUTH__REQUIRED = "Enabled" })
      volumes     = ["/var/lib/arr/radarr:/config", "/data:/data"]
      health      = "curl -fsS -o /dev/null http://127.0.0.1:7878/ping"
    }
    bazarr = {
      description = "Bazarr: subtitles for the Sonarr/Radarr libraries"
      user        = ""
      env         = local.arr_lsio_env
      volumes     = ["/var/lib/arr/bazarr:/config", "/data/library:/data/library"]
      health      = "curl -fsS -o /dev/null http://127.0.0.1:6767/"
    }
    jellyfin = {
      description = "Jellyfin: media server for /data/library (read-only)"
      user        = tostring(var.arr.uid)
      env         = { TZ = var.arr.timezone, JELLYFIN_PublishedServerUrl = "https://jellyfin.lylat.space" }
      volumes     = ["/var/lib/arr/jellyfin/config:/config", "/var/lib/arr/jellyfin/cache:/cache", "/data/library:/data/library:ro"]
      health      = "curl -fsS -o /dev/null http://127.0.0.1:8096/health"
    }
    seerr = {
      description = "Seerr: request page for Jellyfin users (sends requests to Sonarr/Radarr)"
      user        = ""
      env         = { TZ = var.arr.timezone, LOG_LEVEL = "info", PORT = "5055" }
      volumes     = ["/var/lib/arr/seerr:/app/config"]
      # No quotes in health checks: Quadlet strips them and the command breaks (the first node -e version did).
      health = "wget -q -O /dev/null http://127.0.0.1:5055/api/v1/status"
    }
  }
  # Start order inside the pod: Prowlarr after Sonarr/Radarr so the setup script finds them all up.
  arr_order = ["sonarr", "radarr", "prowlarr", "bazarr", "jellyfin", "seerr"]

  arr_files = {
    for name, vm in(!local.arr_enabled ? {} : local.arr_vms) : name => concat([
      { path = "/etc/ceph/${var.arr.cephfs.client}.secret", mode = "0600", content = var.arr_cephfs_key },
      { path = "/etc/systemd/system/data.mount", units = ["data.mount"], content = templatefile("${path.module}/templates/arr-cephfs.mount.tftpl", {
        what    = "${join(",", [for m in var.arr.cephfs.monitors : "${m}:6789"])}:${var.arr.cephfs.path}"
        options = "name=${var.arr.cephfs.client},secretfile=/etc/ceph/${var.arr.cephfs.client}.secret,mds_namespace=${var.arr.cephfs.fs},noatime,_netdev"
      }) },
      { path = "/etc/containers/systemd/arr.pod", units = ["arr-pod"], content = templatefile("${path.module}/templates/arr.pod.tftpl", {
        listen = local.arr_listen[name]
        ports  = [for app in local.arr_order : local.arr_ports[app]]
      }) },
      ], [
      for app in local.arr_order : {
        path  = "/etc/containers/systemd/${app}.container"
        units = [app]
        content = templatefile("${path.module}/templates/arr-app.container.tftpl", merge(local.arr_apps[app], {
          name  = app
          image = local.container_images[app]
        }))
      }
      ], [
      { path = "/deploy/arr-setup.sh", stage_only = true, mode = "0700", content = templatefile("${path.module}/templates/arr-setup.sh.tftpl", {
        host           = local.arr_listen[name]
        uid            = var.arr.uid
        admin_user     = var.arr.admin_user
        admin_password = random_password.arr_admin[0].result
        sonarr_key     = local.arr_key["sonarr"]
        radarr_key     = local.arr_key["radarr"]
        prowlarr_key   = local.arr_key["prowlarr"]
      }) },
    ])
  }
}

module "arr" {
  source   = "../../modules/services/quadlet-deploy"
  for_each = local.arr_files

  name     = "arr"
  host     = each.key
  files    = each.value
  units    = concat(["data.mount", "arr-pod"], local.arr_order)
  images   = [for app in local.arr_order : local.container_images[app]]
  packages = ["ceph-common", "curl", "jq"]
  dirs = concat([{ path = "/data" }, { path = "/var/lib/arr", mode = "0750" }], [
    for d in ["prowlarr", "sonarr", "radarr", "bazarr", "jellyfin", "jellyfin/config", "jellyfin/cache"] :
    { path = "/var/lib/arr/${d}", mode = "0750", owner = "${var.arr.uid}:${var.arr.uid}" }
    ], [
    { path = "/var/lib/arr/seerr", mode = "0750", owner = "1000:1000" }, # the Seerr image runs as node (1000)
  ])
  post_install = [
    "systemctl enable --quiet data.mount",
    "systemctl start data.mount",
    "mountpoint -q /data",
    "test -d /data/torrents && test -d /data/library/tv && test -d /data/library/movies",
  ]
  verify = concat(
    [for app in local.arr_order : "retry curl -fsS -o /dev/null --max-time 5 'http://${local.arr_listen[each.key]}:${local.arr_ports[app]}${app == "jellyfin" ? "/health" : app == "seerr" ? "/api/v1/status" : app == "bazarr" ? "/" : "/ping"}'"],
    ["bash \"$stage/deploy/arr-setup.sh\""],
  )
}

resource "terraform_data" "arr" {
  for_each = local.arr_files

  triggers_replace = [
    sha256(module.arr[each.key].script),
    local.arr_vms[each.key].management_address,
    local.arr_vms[each.key].vm_id,
  ]

  connection {
    type        = "ssh"
    host        = split("/", local.arr_vms[each.key].management_address)[0]
    user        = local.arr_vms[each.key].config.ssh_username
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = ["install -d -m 0700 /tmp/tofu-arr-${self.id}"]
  }

  provisioner "file" {
    content     = module.arr[each.key].script
    destination = "/tmp/tofu-arr-${self.id}/deploy.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "rc=0; sudo -n bash /tmp/tofu-arr-${self.id}/deploy.sh || rc=$?; rm -rf /tmp/tofu-arr-${self.id}; exit $rc",
    ]
  }
}

output "arr_url" {
  description = "arr stack: the web UIs (login: var.arr.admin_user, password: tofu output -raw arr_admin_password)."
  value = !local.arr_enabled ? {} : merge(
    { for app, port in local.arr_ports : app => "https://${app}.lylat.space/" },
    { login = "${var.arr.admin_user} / tofu output -raw arr_admin_password (Seerr: sign in with the Jellyfin account)" },
  )
}

output "arr_admin_password" {
  description = "Initial password of the arr apps' admin user (set by the first deploy only; changing it in an app doesn't update this)."
  value       = local.arr_enabled ? random_password.arr_admin[0].result : null
  sensitive   = true
}
