# Valkey + Sentinel for NetBox (cache and task queue) on the role = "valkey" VMs (valkey01-03),
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
# changed. An nftables table limits 6379/26379 to the NetBox and Valkey VMs.
variable "valkey" {
  description = "Valkey + Sentinel for NetBox on the role = \"valkey\" VMs. null = don't deploy."
  type = object({
    master_name         = optional(string, "netbox") # Sentinel's name for the replicated set (NetBox's REDIS_SENTINEL_SERVICE)
    quorum              = optional(number, 2)        # Sentinels that must agree the primary is down
    down_after_ms       = optional(number, 5000)     # no reply for this long = subjectively down
    failover_timeout_ms = optional(number, 60000)
    maxmemory           = optional(string, "512mb")
    backend_vlan_id     = optional(number, 13)
  })
  default = {}
}

resource "random_password" "valkey" {
  count   = var.valkey != null && length(local.valkey_vms) > 0 ? 1 : 0
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

  # Who may reach Valkey/Sentinel: the trio itself and the NetBox VMs (backend addresses).
  valkey_clients = local.valkey_enabled ? sort(concat(values(local.valkey_backend), flatten([
    for name, vm in var.vms : [
      for nic in vm.network_devices : split("/", nic.ipv4_address)[0]
      if nic.vlan_id == var.valkey.backend_vlan_id && nic.ipv4_address != null
    ] if vm.owner == "services-vms" && vm.role == "netbox"
  ]))) : []

  valkey_script = !local.valkey_enabled ? {} : {
    for name, vm in local.valkey_vms : name => templatefile("${path.module}/templates/valkey-deploy.sh.tftpl", {
      address         = local.valkey_backend[name]
      initial_primary = local.valkey_backend[local.valkey_names[0]]
      peers           = [for peer in local.valkey_names : local.valkey_backend[peer] if peer != name]
      master_name     = var.valkey.master_name
      server_b64 = base64encode(templatefile("${path.module}/templates/valkey.conf.tftpl", {
        address   = local.valkey_backend[name]
        password  = random_password.valkey[0].result
        maxmemory = var.valkey.maxmemory
      }))
      sentinel_b64 = base64encode(templatefile("${path.module}/templates/valkey-sentinel.conf.tftpl", {
        address             = local.valkey_backend[name]
        master_name         = var.valkey.master_name
        quorum              = var.valkey.quorum
        password            = random_password.valkey[0].result
        down_after_ms       = var.valkey.down_after_ms
        failover_timeout_ms = var.valkey.failover_timeout_ms
      }))
      nft_b64 = base64encode(templatefile("${path.module}/templates/valkey.nft.tftpl", {
        clients = local.valkey_clients
      }))
    })
  }

  valkey_canary = { for name, s in local.valkey_script : name => s if name == local.valkey_names[0] }
  valkey_rest   = { for name, s in local.valkey_script : name => s if name != local.valkey_names[0] }
}

resource "terraform_data" "valkey_canary" {
  for_each = local.valkey_canary

  triggers_replace = [
    sha256(each.value),
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
    content     = each.value
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
    sha256(each.value),
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
    content     = each.value
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
