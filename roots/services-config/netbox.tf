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
# HA: keepalived holds var.netbox.vip on the VLAN 2 NIC of a node whose NetBox answers /login/;
# adverts go unicast over the HA L2VNI (l2vnis.ha_netbox). NetBox is published on the node's own
# VLAN 2 address and the VIP, ports 80 and 8000. Deploys are canary-first like dark-triage.
variable "netbox" {
  description = "NetBox image, database, superuser and VIP. null = don't deploy."
  type = object({
    image = optional(string, "docker.io/netboxcommunity/netbox:v4.7-5.1.1")
    database = optional(object({
      host = optional(string, "10.13.11.104") # Patroni VIP (backend VLAN 13)
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
    # keepalived VIP on VLAN 2 (netbox.lylat.space points here). null = no keepalived.
    vip       = optional(string, "10.2.11.106/16")
    router_id = optional(number, 106) # = the VIP's last octet (Grafana 100 ... dark-triage 105)
    ha_l2vni  = optional(string, "ha_netbox")
  })
  default = {}

  validation {
    condition = var.netbox == null || try(
      (var.netbox.vip == null || (can(cidrhost(var.netbox.vip, 0)) && strcontains(var.netbox.vip, "/"))) &&
      var.netbox.router_id >= 1 && var.netbox.router_id <= 255, false
    )
    error_message = "netbox.vip must be an IPv4 address with prefix length (e.g. 10.2.11.106/16), router_id 1..255."
  }
}

# SECRET_KEY (sessions, password reset links) and the API token pepper (v2 tokens are stored as
# HMACs with it): the same on both nodes. Changing either logs everyone out / breaks every token.
variable "netbox_cephfs_key" {
  description = "CephFS key of client.netbox (netbox.secret.auto.tfvars, git-ignored). null = media/scripts/reports stay local to each VM."
  type        = string
  sensitive   = true
  default     = null
}

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

resource "random_password" "netbox_vrrp" {
  count   = local.netbox_enabled ? 1 : 0
  length  = 8 # VRRP PASS authentication uses at most 8 characters.
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

  # network_devices[i] is eth<i+1>: NetBox listens on the VLAN 2 NIC (the one with the gateway);
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
    GRAPHQL_ENABLED        = "true"
    WEBHOOKS_ENABLED       = "true"
    METRICS_ENABLED        = "true"
    MEDIA_ROOT             = "/opt/netbox/netbox/media"
    RELEASE_CHECK_URL      = "https://api.github.com/repos/netbox-community/netbox/releases"
  } : "${k}=${v}\n"])

  netbox_script = !local.netbox_enabled ? {} : {
    for name, vm in local.netbox_vms : name => templatefile("${path.module}/templates/netbox-deploy.sh.tftpl", {
      image  = var.netbox.image
      listen = local.netbox_nics[name].service.address
      ha     = local.netbox_ha
      cephfs = local.netbox_cephfs
      # base64 so the key never appears in the script as plain text (it is still in tofu's state).
      cephfs_key_b64 = local.netbox_cephfs ? base64encode(var.netbox_cephfs_key) : ""
      mount_b64 = !local.netbox_cephfs ? "" : base64encode(templatefile("${path.module}/templates/netbox-cephfs.mount.tftpl", {
        what    = "${join(",", [for m in var.netbox.cephfs.monitors : "${m}:6789"])}:${var.netbox.cephfs.path}"
        options = "name=${var.netbox.cephfs.client},secretfile=/etc/ceph/${var.netbox.cephfs.client}.secret,mds_namespace=${var.netbox.cephfs.fs},noatime,_netdev"
      }))
      env_b64 = base64encode(local.netbox_env)
      unit_b64 = base64encode(templatefile("${path.module}/templates/netbox.container.tftpl", {
        image     = var.netbox.image
        addresses = compact([local.netbox_nics[name].service.address, local.netbox_vip])
        ports     = var.netbox.ports
      }))
      worker_b64 = base64encode(templatefile("${path.module}/templates/netbox-worker.container.tftpl", {
        image = var.netbox.image
      }))
      keepalived_b64 = !local.netbox_ha ? "" : base64encode(templatefile("${path.module}/templates/netbox-keepalived.conf.tftpl", {
        host         = name
        ha_interface = local.netbox_nics[name].ha.interface
        ha_address   = local.netbox_nics[name].ha.address
        peers        = [for peer, n in local.netbox_nics : n.ha.address if peer != name]
        router_id    = var.netbox.router_id
        # Only the first election: nopreempt keeps the VIP where it is afterwards.
        priority  = name == local.netbox_names[0] ? 150 : 100
        auth_pass = random_password.netbox_vrrp[0].result
        vip       = var.netbox.vip
        interface = local.netbox_nics[name].service.interface
      }))
      check_b64 = base64encode(templatefile("${path.module}/templates/netbox-keepalived-check.sh.tftpl", {
        url = "http://${local.netbox_nics[name].service.address}/login/"
      }))
    })
  }

  netbox_canary = { for name, s in local.netbox_script : name => s if name == local.netbox_names[0] }
  netbox_rest   = { for name, s in local.netbox_script : name => s if name != local.netbox_names[0] }
}

resource "terraform_data" "netbox_canary" {
  for_each   = local.netbox_canary
  depends_on = [terraform_data.valkey_canary, terraform_data.valkey]

  triggers_replace = [
    sha256(each.value),
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
    content     = each.value
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
    sha256(each.value),
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
    content     = each.value
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
    local.netbox_vip == null || !local.netbox_enabled ? {} : { vip = "http://${local.netbox_vip}/ (http://netbox.lylat.space/)" },
    { for name, n in local.netbox_nics : name => "http://${n.service.address}/" },
  )
}
