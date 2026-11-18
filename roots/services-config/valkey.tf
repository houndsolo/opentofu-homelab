# Valkey + Sentinel for NetBox (cache and task queue) and Nextcloud (file locking, cache and PHP sessions;
# nextcloud.tf) on the role = "valkey" VMs (valkey01-03),
# from Debian's packages. Every VM runs valkey-server (6379) and valkey-sentinel (26379) on its
# backend VLAN address (plus loopback). The first VM by name starts as the primary, the others
# replicate from it. The Sentinels watch the primary; when a quorum of them (2 of 3) agrees it's
# down, they promote a replica and repoint the rest. NetBox never talks to a fixed address: it asks
# the Sentinels which node is the primary (REDIS_SENTINELS, netbox.tf).
#
# After the first deploy the Sentinels own the replication topology (they rewrite valkey.conf and
# sentinel.conf). A deploy therefore asks the running Sentinels for the current primary and writes
# valkey.conf to match, and only writes sentinel.conf the first time or when its settings change.
# Deploys are canary-first (first VM, then the rest) and restart a service only when its config
# changed. An nftables table limits 6379/26379 to the NetBox, Nextcloud, Gitea and Valkey VMs.
#
# Memory: maxmemory with noeviction (locks and task queues must never be evicted), so a full Valkey refuses
# writes for every app at once. Keep maxmemory well under the VMs' RAM (2 GB) and watch used/max.
variable "valkey" {
  description = "Valkey + Sentinel (shared by NetBox, Nextcloud and Gitea) on the role = \"valkey\" VMs. null = don't deploy."
  type = object({
    master_name         = optional(string, "netbox") # Sentinel's name for the replicated set (NetBox's REDIS_SENTINEL_SERVICE)
    quorum              = optional(number, 2)        # Sentinels that must agree the primary is down
    down_after_ms       = optional(number, 5000)     # no reply for this long = subjectively down
    failover_timeout_ms = optional(number, 60000)
    maxmemory           = optional(string, "1gb") # NetBox + Nextcloud; the VMs have 2 GB
    backend_vlan_id     = optional(number, 1601)  # lylat-data: Valkey + Sentinel listen here
    client_vlan_id      = optional(number, 1201)  # lylat-app: the NetBox and Nextcloud VMs' NIC (routed to lylat-data)
  })
  default = {}
}

resource "random_password" "valkey" {
  count   = local.valkey_enabled ? 1 : 0
  length  = 32
  special = false
}

locals {
  valkey_vms     = { for name, vm in var.vms : name => vm if vm.owner == "services-vms" && vm.role == "valkey" }
  valkey_names   = sort(keys(local.valkey_vms))
  valkey_enabled = var.valkey != null && length(local.valkey_vms) > 0

  # Backend VLAN address of a VM (network_devices[i] is eth<i+1>; eth0 is management).
  valkey_backend = local.valkey_enabled ? {
    for name, vm in local.valkey_vms : name => one([
      for nic in vm.network_devices : split("/", nic.ipv4_address)[0]
      if nic.vlan_id == var.valkey.backend_vlan_id && nic.ipv4_address != null
    ])
  } : {}
  valkey_sentinels = [for name in local.valkey_names : "${local.valkey_backend[name]}:26379"]

  # Who may reach Valkey/Sentinel: the trio itself and the NetBox, Nextcloud and Gitea VMs (their lylat-app addresses).
  valkey_clients = local.valkey_enabled ? sort(concat(values(local.valkey_backend), flatten([
    for vm in values(merge(local.netbox_vms, local.nextcloud_vms, local.gitea_vms)) : [ # netbox.tf, nextcloud.tf, gitea.tf
      for nic in vm.network_devices : split("/", nic.ipv4_address)[0]
      if nic.vlan_id == var.valkey.client_vlan_id && nic.ipv4_address != null
    ]
  ]))) : []

  # The deploy (modules/services/quadlet-deploy): Debian's packages, the nftables table (own unit, loaded
  # first), the managed settings in /etc/valkey/tofu, then templates/valkey-apply.sh.tftpl writes the live
  # configs for the current primary and restarts only what changed (see its header), and waits for health.
  valkey_files = {
    for name, vm in(!local.valkey_enabled ? {} : local.valkey_vms) : name => [
      { path = "/etc/nftables-valkey.nft", content = templatefile("${path.module}/templates/valkey.nft.tftpl", { clients = local.valkey_clients }) },
      { path = "/etc/systemd/system/valkey-nft.service", content = file("${path.module}/templates/valkey-nft.service") },
      { path = "/etc/valkey/tofu/valkey.conf", mode = "0600", content = templatefile("${path.module}/templates/valkey.conf.tftpl", {
        address   = local.valkey_backend[name]
        password  = random_password.valkey[0].result
        maxmemory = var.valkey.maxmemory
      }) },
      { path = "/etc/valkey/tofu/sentinel.conf", mode = "0600", content = templatefile("${path.module}/templates/valkey-sentinel.conf.tftpl", {
        address             = local.valkey_backend[name]
        master_name         = var.valkey.master_name
        quorum              = var.valkey.quorum
        password            = random_password.valkey[0].result
        down_after_ms       = var.valkey.down_after_ms
        failover_timeout_ms = var.valkey.failover_timeout_ms
      }) },
      { path = "/etc/valkey/tofu/apply.sh", mode = "0755", content = templatefile("${path.module}/templates/valkey-apply.sh.tftpl", {
        address         = local.valkey_backend[name]
        initial_primary = local.valkey_backend[local.valkey_names[0]]
        peers           = [for peer in local.valkey_names : local.valkey_backend[peer] if peer != name]
        master_name     = var.valkey.master_name
      }) },
    ]
  }

  valkey_canary = { for name, f in local.valkey_files : name => f if name == local.valkey_names[0] }
  valkey_rest   = { for name, f in local.valkey_files : name => f if name != local.valkey_names[0] }
}

module "valkey" {
  source   = "../../modules/services/quadlet-deploy"
  for_each = local.valkey_files

  name     = "valkey"
  host     = each.key
  files    = each.value
  units    = ["valkey-server", "valkey-sentinel"]
  packages = ["valkey-server", "valkey-sentinel", "nftables"]
  checks   = ["nft -c -f \"$stage/etc/nftables-valkey.nft\""]
  post_install = [
    # Firewall first, on every deploy: 6379/26379 only for the trio and the client VMs.
    "systemctl enable --quiet valkey-nft.service valkey-server.service valkey-sentinel.service",
    "systemctl restart valkey-nft.service",
    "/etc/valkey/tofu/apply.sh",
  ]
}

resource "terraform_data" "valkey_canary" {
  for_each = local.valkey_canary

  triggers_replace = [
    sha256(module.valkey[each.key].script),
    local.valkey_vms[each.key].management_address,
    local.valkey_vms[each.key].vm_id,
  ]

  connection {
    type        = "ssh"
    host        = split("/", local.valkey_vms[each.key].management_address)[0]
    user        = local.valkey_vms[each.key].config.ssh_username
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = ["install -d -m 0700 /tmp/tofu-valkey-${self.id}"]
  }

  provisioner "file" {
    content     = module.valkey[each.key].script
    destination = "/tmp/tofu-valkey-${self.id}/deploy.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "rc=0; sudo -n bash /tmp/tofu-valkey-${self.id}/deploy.sh || rc=$?; rm -rf /tmp/tofu-valkey-${self.id}; exit $rc",
    ]
  }
}

resource "terraform_data" "valkey" {
  for_each   = local.valkey_rest
  depends_on = [terraform_data.valkey_canary]

  triggers_replace = [
    sha256(module.valkey[each.key].script),
    local.valkey_vms[each.key].management_address,
    local.valkey_vms[each.key].vm_id,
  ]

  connection {
    type        = "ssh"
    host        = split("/", local.valkey_vms[each.key].management_address)[0]
    user        = local.valkey_vms[each.key].config.ssh_username
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = ["install -d -m 0700 /tmp/tofu-valkey-${self.id}"]
  }

  provisioner "file" {
    content     = module.valkey[each.key].script
    destination = "/tmp/tofu-valkey-${self.id}/deploy.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "rc=0; sudo -n bash /tmp/tofu-valkey-${self.id}/deploy.sh || rc=$?; rm -rf /tmp/tofu-valkey-${self.id}; exit $rc",
    ]
  }
}

output "valkey_sentinels" {
  description = "Valkey Sentinels (backend VLAN) and the replicated set's name, as NetBox uses them."
  value       = local.valkey_enabled ? { sentinels = local.valkey_sentinels, master_name = var.valkey.master_name } : null
}
