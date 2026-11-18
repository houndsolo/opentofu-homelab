# NetBox (IPAM/DCIM) on the role = "netbox" VMs (netbox01-02): the netbox-docker image
# (docker.io/netboxcommunity/netbox) as two rootful Podman Quadlets per VM, netbox (web UI/API,
# runs the database migrations on start) and netbox-worker (background jobs). Configured only
# through environment variables (the image's built-in configuration.py reads them).
#
# State lives elsewhere, so both VMs serve at once: Postgres on the Patroni cluster (database
# "netbox", created by monitoring-config; TLS without certificate checks, sslmode=require), cache
# and task queue in Valkey, found through the Sentinels on valkey01-03 (valkey.tf). Media, scripts
# and reports live on CephFS: /netbox (client.netbox, key in netbox.secret.auto.tfvars) is mounted
# at /var/lib/netbox on both VMs over their Ceph public network NIC, so an upload on one node is
# there on the other. Without the key they are local directories.
#
# HA: keepalived holds var.netbox.vip on the lylat-app NIC of a node whose NetBox answers /login/;
# adverts go unicast over the HA L2VNI (l2vnis.ha_netbox). NetBox is published on the node's own
# lylat-app address and the VIP, ports 80 and 8000. Deploys are canary-first like dark-triage.
variable "netbox" {
  description = "NetBox image, database, superuser and VIP. null = don't deploy."
  type = object({
    database = optional(object({
      host = optional(string, "10.56.14.104") # Patroni VIP (lylat-data)
      port = optional(number, 5432)
      name = optional(string, "netbox")
      user = optional(string, "netbox")
    }), {})
    # Created on start when no user of that name exists (the restored database has its own users).
    superuser = optional(object({
      name     = optional(string, "admin")
      email    = optional(string, "admin@lylat.space")
      password = optional(string, "admin")
    }), {})
    ports = optional(list(number), [80, 8000])
    # CephFS for media/scripts/reports (used when var.netbox_cephfs_key is set).
    cephfs = optional(object({
      monitors = optional(list(string), ["10.27.0.12", "10.27.0.13", "10.27.0.14", "10.27.0.17"]) # macbeth, titania, zoness, venom
      fs       = optional(string, "cephfs")
      path     = optional(string, "/netbox")
      client   = optional(string, "netbox")
    }), {})
    # keepalived VIP in lylat-app (netbox-vip.lylat.space; users reach https://netbox.lylat.space through
    # the reverse proxy, proxy.tf). null = no keepalived.
    vip       = optional(string, "10.52.12.106/16")
    router_id = optional(number, 106) # = the VIP's last octet (Grafana 100 ... dark-triage 105)
    ha_l2vni  = optional(string, "ha_netbox")
  })
  default = {}

  validation {
    condition = var.netbox == null || try(
      (var.netbox.vip == null || (can(cidrhost(var.netbox.vip, 0)) && strcontains(var.netbox.vip, "/"))) &&
      var.netbox.router_id >= 1 && var.netbox.router_id <= 255, false
    )
    error_message = "netbox.vip must be an IPv4 address with prefix length (e.g. 10.52.12.106/16), router_id 1..255."
  }
}

variable "netbox_cephfs_key" {
  description = "CephFS key of client.netbox (netbox.secret.auto.tfvars, git-ignored). null = media/scripts/reports stay local to each VM."
  type        = string
  sensitive   = true
  default     = null
}

# SECRET_KEY (sessions, password reset links) and the API token pepper (v2 tokens are stored as
# HMACs with it): the same on both nodes. Changing either logs everyone out / breaks every token.
resource "random_password" "netbox_secret_key" {
  count   = local.netbox_enabled ? 1 : 0
  length  = 64
  special = false
}

resource "random_password" "netbox_token_pepper" {
  count   = local.netbox_enabled ? 1 : 0
  length  = 64
  special = false
}

locals {
  netbox_vms   = { for name, vm in var.vms : name => vm if vm.owner == "services-vms" && vm.role == "netbox" }
  netbox_names = sort(keys(local.netbox_vms))
  # Needs its database password and the Valkey trio.
  netbox_enabled = var.netbox != null && length(local.netbox_vms) > 0 && nonsensitive(contains(keys(var.app_db_passwords), "netbox")) && local.valkey_enabled
  netbox_vip     = var.netbox == null ? null : try(split("/", var.netbox.vip)[0], null)
  netbox_cephfs  = local.netbox_enabled && nonsensitive(var.netbox_cephfs_key != null)
  netbox_ha      = local.netbox_enabled && local.netbox_vip != null

  # network_devices[i] is eth<i+1>: NetBox listens on the lylat-app NIC (the one with the gateway);
  # keepalived adverts use the NIC on the HA L2VNI.
  netbox_nics = !local.netbox_enabled ? {} : {
    for name, vm in local.netbox_vms : name => {
      service = one([for i, nic in vm.network_devices : { interface = "eth${i + 1}", address = split("/", nic.ipv4_address)[0] } if nic.ipv4_address != null && nic.ipv4_gateway != null])
      ha = !local.netbox_ha ? null : one([
        for i, nic in vm.network_devices : { interface = "eth${i + 1}", address = split("/", nic.ipv4_address)[0] }
        if nic.vlan_id == var.l2vnis[var.netbox.ha_l2vni].vlan_id && nic.ipv4_address != null
      ])
    }
  }

  netbox_env = !local.netbox_enabled ? "" : join("", [for k, v in {
    DB_HOST                = var.netbox.database.host
    DB_PORT                = var.netbox.database.port
    DB_NAME                = var.netbox.database.name
    DB_USER                = var.netbox.database.user
    DB_PASSWORD            = var.app_db_passwords["netbox"]
    DB_SSLMODE             = "require"
    REDIS_SENTINELS        = join(" ", local.valkey_sentinels) # netbox-docker splits lists on spaces
    REDIS_CACHE_SENTINELS  = join(" ", local.valkey_sentinels) # netbox-docker splits lists on spaces
    REDIS_SENTINEL_SERVICE = var.valkey.master_name
    REDIS_SENTINEL_TIMEOUT = 2
    REDIS_PASSWORD         = random_password.valkey[0].result
    REDIS_DATABASE         = 0
    REDIS_CACHE_DATABASE   = 1
    SECRET_KEY             = random_password.netbox_secret_key[0].result
    API_TOKEN_PEPPER_1     = random_password.netbox_token_pepper[0].result
    SKIP_SUPERUSER         = "false"
    SUPERUSER_NAME         = var.netbox.superuser.name
    SUPERUSER_EMAIL        = var.netbox.superuser.email
    SUPERUSER_PASSWORD     = var.netbox.superuser.password
    CORS_ORIGIN_ALLOW_ALL  = "True"
    # https://<name>.lylat.space of every reverse proxy host that forwards to NetBox's VIP.
    CSRF_TRUSTED_ORIGINS = join(" ", local.netbox_proxy_origins)
    GRAPHQL_ENABLED      = "true"
    WEBHOOKS_ENABLED     = "true"
    METRICS_ENABLED      = "true"
    MEDIA_ROOT           = "/opt/netbox/netbox/media"
    RELEASE_CHECK_URL    = "https://api.github.com/repos/netbox-community/netbox/releases"
  } : "${k}=${v}\n"])

  # The deploy (modules/services/quadlet-deploy). Media, scripts and reports: the CephFS mount comes up and
  # the directories are made before NetBox (re)starts. Health is the unit's (HealthCmd + Notify=healthy,
  # TimeoutStartSec covers the first migration). Units restart only when their unit or env changed (or they
  # aren't running): a deploy that only changes keepalived reloads keepalived and leaves NetBox alone.
  netbox_files = {
    for name, vm in(!local.netbox_enabled ? {} : local.netbox_vms) : name => concat([
      { path = "/etc/containers/systemd/netbox.container", units = ["netbox"], content = templatefile("${path.module}/templates/netbox.container.tftpl", {
        image     = local.container_images.netbox
        addresses = compact([local.netbox_nics[name].service.address, local.netbox_vip])
        ports     = var.netbox.ports
      }) },
      { path = "/etc/containers/systemd/netbox-worker.container", units = ["netbox-worker"], content = templatefile("${path.module}/templates/netbox-worker.container.tftpl", {
        image = local.container_images.netbox
      }) },
      { path = "/etc/netbox/env", mode = "0600", units = ["netbox", "netbox-worker"], restart = true, content = local.netbox_env },
      ], [for f in [
        # CephFS /netbox at /var/lib/netbox (kernel client; mount.ceph comes with ceph-common).
        { path = "/etc/ceph/${var.netbox.cephfs.client}.secret", mode = "0600", content = var.netbox_cephfs_key },
        { path = "/etc/systemd/system/var-lib-netbox.mount", units = ["var-lib-netbox.mount"], content = templatefile("${path.module}/templates/netbox-cephfs.mount.tftpl", {
          what    = "${join(",", [for m in var.netbox.cephfs.monitors : "${m}:6789"])}:${var.netbox.cephfs.path}"
          options = "name=${var.netbox.cephfs.client},secretfile=/etc/ceph/${var.netbox.cephfs.client}.secret,mds_namespace=${var.netbox.cephfs.fs},noatime,_netdev"
        }) },
        ] : f if local.netbox_cephfs], [for f in [
        # The VIP is published on both nodes; only the MASTER holds it.
        { path = "/etc/sysctl.d/90-netbox.conf", content = "net.ipv4.ip_nonlocal_bind = 1\n" },
        { path = "/etc/keepalived/keepalived.conf", mode = "0600", units = ["keepalived"], content = templatefile("${path.module}/templates/netbox-keepalived.conf.tftpl", {
          host         = name
          ha_interface = local.netbox_nics[name].ha.interface
          ha_address   = local.netbox_nics[name].ha.address
          peers        = [for peer, n in local.netbox_nics : n.ha.address if peer != name]
          router_id    = var.netbox.router_id
          # Only the first election: nopreempt keeps the VIP where it is afterwards.
          priority  = name == local.netbox_names[0] ? 150 : 100
          vip       = var.netbox.vip
          interface = local.netbox_nics[name].service.interface
        }) },
        # enable_script_security: the check must be root-owned and not writable by others.
        { path = "/etc/keepalived/chk_netbox.sh", mode = "0755", units = ["keepalived"], content = templatefile("${path.module}/templates/netbox-keepalived-check.sh.tftpl", {
          url = "http://${local.netbox_nics[name].service.address}/login/"
        }) },
    ] : f if local.netbox_ha])
  }

  netbox_canary = { for name, f in local.netbox_files : name => f if name == local.netbox_names[0] }
  netbox_rest   = { for name, f in local.netbox_files : name => f if name != local.netbox_names[0] }
}

module "netbox" {
  source   = "../../modules/services/quadlet-deploy"
  for_each = local.netbox_files

  name     = "netbox"
  host     = each.key
  files    = each.value
  units    = concat(local.netbox_cephfs ? ["var-lib-netbox.mount"] : [], ["netbox", "netbox-worker"], local.netbox_ha ? ["keepalived"] : [])
  images   = [local.container_images.netbox]
  packages = concat(local.netbox_cephfs ? ["ceph-common"] : [], local.netbox_ha ? ["keepalived"] : [])
  dirs     = [{ path = "/etc/netbox" }, { path = "/var/lib/netbox" }]
  checks   = local.netbox_ha ? ["keepalived -t -f \"$stage/etc/keepalived/keepalived.conf\""] : []
  post_install = concat(local.netbox_ha ? [
    "sysctl -q -p /etc/sysctl.d/90-netbox.conf",
    "systemctl enable --quiet keepalived.service",
    ] : [], local.netbox_cephfs ? [
    "systemctl enable --quiet var-lib-netbox.mount",
    "systemctl start var-lib-netbox.mount",
    "mountpoint -q /var/lib/netbox",
    ] : [], [
    # On CephFS when mounted, so after the mount. The image runs as netbox (uid 999), group root.
    "for d in media reports scripts; do install -d -m 0775 -o 999 -g 0 /var/lib/netbox/$d; done",
  ])
  # The published port on the node's own address (the unit's HealthCmd checks inside the container).
  verify = ["retry curl -fsS -o /dev/null --max-time 3 'http://${local.netbox_nics[each.key].service.address}/login/'"]
}

resource "terraform_data" "netbox_canary" {
  for_each   = local.netbox_canary
  depends_on = [terraform_data.valkey_canary, terraform_data.valkey]

  triggers_replace = [
    sha256(module.netbox[each.key].script),
    local.netbox_vms[each.key].management_address,
    local.netbox_vms[each.key].vm_id,
  ]

  connection {
    type        = "ssh"
    host        = split("/", local.netbox_vms[each.key].management_address)[0]
    user        = local.netbox_vms[each.key].config.ssh_username
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = ["install -d -m 0700 /tmp/tofu-netbox-${self.id}"]
  }

  provisioner "file" {
    content     = module.netbox[each.key].script
    destination = "/tmp/tofu-netbox-${self.id}/deploy.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "rc=0; sudo -n bash /tmp/tofu-netbox-${self.id}/deploy.sh || rc=$?; rm -rf /tmp/tofu-netbox-${self.id}; exit $rc",
    ]
  }
}

resource "terraform_data" "netbox" {
  for_each   = local.netbox_rest
  depends_on = [terraform_data.netbox_canary]

  triggers_replace = [
    sha256(module.netbox[each.key].script),
    local.netbox_vms[each.key].management_address,
    local.netbox_vms[each.key].vm_id,
  ]

  connection {
    type        = "ssh"
    host        = split("/", local.netbox_vms[each.key].management_address)[0]
    user        = local.netbox_vms[each.key].config.ssh_username
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = ["install -d -m 0700 /tmp/tofu-netbox-${self.id}"]
  }

  provisioner "file" {
    content     = module.netbox[each.key].script
    destination = "/tmp/tofu-netbox-${self.id}/deploy.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "rc=0; sudo -n bash /tmp/tofu-netbox-${self.id}/deploy.sh || rc=$?; rm -rf /tmp/tofu-netbox-${self.id}; exit $rc",
    ]
  }
}

output "netbox_url" {
  description = "NetBox URLs: the VIP and each node."
  value = merge(
    local.netbox_vip == null || !local.netbox_enabled ? {} : { vip = "http://${local.netbox_vip}/ (users: ${join(", ", local.netbox_proxy_origins)})" },
    { for name, n in local.netbox_nics : name => "http://${n.service.address}/" },
  )
}
