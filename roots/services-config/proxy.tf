# Reverse proxy for the VLAN 2 services: nginx (Debian package) on every role "proxy" VM terminates
# TLS for <name>.<domain> (*.svc.lylat.space) with the Let's Encrypt wildcard that roots/certs
# installs in var.proxy.cert_dir, and forwards to the service VIPs over plain HTTP.
#
# HA: both nodes run nginx all the time with the same config (stateless). keepalived holds
# var.proxy.vip on the VLAN 2 NIC of a node whose nginx answers /healthz, with use_vmac (fixed MAC,
# DT-045); adverts go unicast over the HA L2VNI (l2vnis.ha_proxy). nginx listens on all addresses,
# so the VIP needs no ip_nonlocal_bind. nftables limits 80/443 to var.proxy.clients.
#
# Order: roots/certs first (the deploy stops if the certificate is missing). Deploys are
# canary-first: the first VM (sorted by name) must pass its health check before the others.
variable "proxy" {
  description = "Reverse proxy: hostnames (<key>.<domain>) and their upstreams, certificate path, VIP. null = don't deploy."
  type = object({
    domain   = optional(string, "svc.lylat.space")
    cert_dir = optional(string, "/etc/ssl/svc") # = roots/certs var.certificate.directory
    hosts = optional(map(object({
      upstream   = string                  # scheme://host:port, normally a service VIP
      websockets = optional(bool, false)   # Upgrade/Connection headers (Grafana Live)
      max_body   = optional(string, "10m") # client_max_body_size (uploads)
      })), {
      grafana = { upstream = "http://10.2.11.100:3000", websockets = true }
      netbox  = { upstream = "http://10.2.11.106:80", max_body = "100m" }
      triage  = { upstream = "http://10.2.11.105:80" }
    })
    clients = optional(list(string), ["10.0.0.0/8"]) # may reach 80/443
    # keepalived VIP on VLAN 2 (proxy.lylat.space). null = no keepalived.
    vip       = optional(string, "10.2.11.107/16")
    router_id = optional(number, 107) # = the VIP's last octet, like Grafana 100 ... NetBox 106
    ha_l2vni  = optional(string, "ha_proxy")
  })
  default = {}

  validation {
    condition = var.proxy == null || try(
      (var.proxy.vip == null || (can(cidrhost(var.proxy.vip, 0)) && strcontains(var.proxy.vip, "/"))) &&
      var.proxy.router_id >= 1 && var.proxy.router_id <= 255 &&
      alltrue([for name, h in var.proxy.hosts : can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$", name)) && can(regex("^https?://[^/]+$", h.upstream))]) &&
      alltrue([for c in var.proxy.clients : can(cidrhost(c, 0))]), false
    )
    error_message = "proxy: vip is an IPv4 address with prefix length, router_id 1..255, host keys are single DNS labels, upstreams are scheme://host:port without a path, clients are CIDRs."
  }
}

resource "random_password" "proxy_vrrp" {
  count   = var.proxy != null ? 1 : 0
  length  = 8 # VRRP PASS authentication uses at most 8 characters.
  special = false
}

locals {
  proxy_vms   = { for name, vm in var.vms : name => vm if vm.owner == "services-vms" && vm.role == "proxy" }
  proxy_names = sort(keys(local.proxy_vms))
  proxy_vip   = var.proxy == null ? null : try(split("/", var.proxy.vip)[0], null)
  proxy_ha    = var.proxy != null && local.proxy_vip != null

  # network_devices[i] is eth<i+1> (eth0 is management): the VIP goes on the VLAN 2 NIC (the one
  # with the gateway), keepalived adverts on the NIC in the HA L2VNI.
  proxy_nics = {
    for name, vm in local.proxy_vms : name => {
      service = one([for i, nic in vm.network_devices : { interface = "eth${i + 1}", address = split("/", nic.ipv4_address)[0] } if nic.ipv4_address != null && nic.ipv4_gateway != null])
      ha = !local.proxy_ha ? null : one([
        for i, nic in vm.network_devices : { interface = "eth${i + 1}", address = split("/", nic.ipv4_address)[0] }
        if nic.vlan_id == var.l2vnis[var.proxy.ha_l2vni].vlan_id && nic.ipv4_address != null
      ])
    }
  }

  proxy_nginx_conf = var.proxy == null ? "" : templatefile("${path.module}/templates/proxy-nginx.conf.tftpl", {
    domain   = var.proxy.domain
    cert_dir = var.proxy.cert_dir
    hosts    = var.proxy.hosts
  })

  proxy_script = var.proxy == null ? {} : {
    for name, vm in local.proxy_vms : name => templatefile("${path.module}/templates/proxy-deploy.sh.tftpl", {
      cert_dir   = var.proxy.cert_dir
      listen     = local.proxy_nics[name].service.address
      ha         = local.proxy_ha
      nginx_b64  = base64encode(local.proxy_nginx_conf)
      nft_b64    = base64encode(templatefile("${path.module}/templates/proxy.nft.tftpl", { clients = var.proxy.clients }))
      host_names = [for h in sort(keys(var.proxy.hosts)) : "${h}.${var.proxy.domain}"]
      keepalived_b64 = !local.proxy_ha ? "" : base64encode(templatefile("${path.module}/templates/proxy-keepalived.conf.tftpl", {
        host         = name
        ha_interface = local.proxy_nics[name].ha.interface
        ha_address   = local.proxy_nics[name].ha.address
        peers        = [for peer, n in local.proxy_nics : n.ha.address if peer != name]
        router_id    = var.proxy.router_id
        # Only the first election: nopreempt keeps the VIP where it is afterwards.
        priority  = name == local.proxy_names[0] ? 150 : 100
        auth_pass = random_password.proxy_vrrp[0].result
        vip       = var.proxy.vip
        interface = local.proxy_nics[name].service.interface
      }))
      check_b64 = base64encode(templatefile("${path.module}/templates/proxy-keepalived-check.sh.tftpl", {
        url = "http://127.0.0.1/healthz"
      }))
    })
  }

  # Canary first: the first VM by name, then everything else (depends_on).
  proxy_canary = { for name, s in local.proxy_script : name => s if name == local.proxy_names[0] }
  proxy_rest   = { for name, s in local.proxy_script : name => s if name != local.proxy_names[0] }
}

resource "terraform_data" "proxy_canary" {
  for_each = local.proxy_canary

  triggers_replace = [
    sha256(each.value),
    local.proxy_vms[each.key].management_address,
    local.proxy_vms[each.key].vm_id,
  ]

  connection {
    type        = "ssh"
    host        = split("/", local.proxy_vms[each.key].management_address)[0]
    user        = local.proxy_vms[each.key].config.ssh_username
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = ["install -d -m 0700 /tmp/tofu-proxy-${self.id}"]
  }

  provisioner "file" {
    content     = each.value
    destination = "/tmp/tofu-proxy-${self.id}/deploy.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "rc=0; sudo -n bash /tmp/tofu-proxy-${self.id}/deploy.sh || rc=$?; rm -rf /tmp/tofu-proxy-${self.id}; exit $rc",
    ]
  }
}

resource "terraform_data" "proxy" {
  for_each   = local.proxy_rest
  depends_on = [terraform_data.proxy_canary]

  triggers_replace = [
    sha256(each.value),
    local.proxy_vms[each.key].management_address,
    local.proxy_vms[each.key].vm_id,
  ]

  connection {
    type        = "ssh"
    host        = split("/", local.proxy_vms[each.key].management_address)[0]
    user        = local.proxy_vms[each.key].config.ssh_username
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = ["install -d -m 0700 /tmp/tofu-proxy-${self.id}"]
  }

  provisioner "file" {
    content     = each.value
    destination = "/tmp/tofu-proxy-${self.id}/deploy.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "rc=0; sudo -n bash /tmp/tofu-proxy-${self.id}/deploy.sh || rc=$?; rm -rf /tmp/tofu-proxy-${self.id}; exit $rc",
    ]
  }
}

output "proxy_urls" {
  description = "Reverse proxy: each published hostname and its upstream; the VIP."
  value = var.proxy == null ? {} : merge(
    { for name, h in var.proxy.hosts : "https://${name}.${var.proxy.domain}/" => h.upstream },
    local.proxy_vip == null ? {} : { vip = "${local.proxy_vip} (proxy.lylat.space)" },
  )
}
