# Reverse proxy for the VLAN 2 web UIs: nginx (Podman Quadlet container, pinned official image, host
# network; config in /etc/nginx-proxy) on every role "proxy" VM terminates
# TLS for https://<name>.lylat.space with the Let's Encrypt wildcard *.lylat.space that roots/certs
# installs in var.proxy.cert_dir, and forwards over plain HTTP to the service's own VIP (its address
# from vips.auto.tfvars, e.g. grafana-vip). DNS: every host name and alias is generated as a CNAME
# to proxy-vip.lylat.space (dns-records.tf).
#
# A deploy that restarts nginx (new image/unit) on the node holding the VIP first hands the VIP to a
# healthy peer (stops keepalived), so the switch costs ~1 s instead of the ~9 s health-check failover.
#
# HA: both nodes run nginx all the time with the same config (stateless). keepalived holds
# var.proxy.vip on the VLAN 2 NIC of a node whose nginx answers /healthz, with use_vmac (fixed MAC,
# DT-045); adverts go unicast over the HA L2VNI (l2vnis.ha_proxy). nginx listens on all addresses,
# so the VIP needs no ip_nonlocal_bind. nftables limits 80/443 to var.proxy.clients.
#
# Order: roots/certs first (the deploy stops if the certificate is missing). Deploys are
# canary-first: the first VM (sorted by name) must pass its health check before the others.
variable "proxy" {
  description = "Reverse proxy: published hosts (<key>.<domain> plus aliases) and the VIP + port they forward to, certificate path, proxy VIP. null = don't deploy."
  type = object({
    image    = optional(string, "docker.io/library/nginx:1.30.6") # nginx stable; bump the tag to upgrade
    domain   = optional(string, "lylat.space")                    # the zone; the certificate is *.<domain>
    cert_dir = optional(string, "/etc/ssl/svc")                   # = roots/certs var.certificate.directory
    hosts = optional(map(object({
      vip        = string                     # key in vips.auto.tfvars: nginx forwards to its address
      port       = number                     # the service's port on that VIP
      aliases    = optional(list(string), []) # more names in the same zone (also CNAMEs to the proxy)
      websockets = optional(bool, false)      # Upgrade/Connection headers (Grafana Live)
      max_body   = optional(string, "10m")    # client_max_body_size (uploads)
      })), {
      grafana       = { vip = "grafana-vip", port = 3000, websockets = true }
      netbox        = { vip = "netbox-vip", port = 80, max_body = "100m" }
      "dark-triage" = { vip = "dark-triage-vip", port = 80, aliases = ["triage"] }
    })
    clients = optional(list(string), ["10.0.0.0/8"]) # may reach 80/443
    # Landing page https://<name>.<domain>: links to every published host. null = none.
    landing = optional(object({
      name  = optional(string, "proxy")
      title = optional(string, "lylat.space services")
    }), {})
    # Proxmox web UIs (:8006, the nodes' self-signed HTTPS) from var.nodes: https://<cluster_name>.<domain>
    # load-balances over every cluster node (ip_hash keeps a browser on one node: noVNC/xterm.js consoles),
    # https://<node_prefix><node>.<domain> reaches one node, the standalone host (greatfox) included. Plain
    # <node>.<domain> is already the node's own A record. null = none.
    pve = optional(object({
      cluster_name = optional(string, "pve")
      node_prefix  = optional(string, "pve-")
      port         = optional(number, 8006)
      max_body     = optional(string, "0") # ISO/template uploads: no limit (streamed, not buffered)
    }), {})
    # keepalived VIP on VLAN 2 (proxy-vip.lylat.space). null = no keepalived.
    vip       = optional(string, "10.2.11.107/16")
    router_id = optional(number, 107) # = the VIP's last octet, like Grafana 100 ... NetBox 106
    ha_l2vni  = optional(string, "ha_proxy")
  })
  default = {}

  validation {
    condition = var.proxy == null || try(
      (var.proxy.vip == null || (can(cidrhost(var.proxy.vip, 0)) && strcontains(var.proxy.vip, "/"))) &&
      var.proxy.router_id >= 1 && var.proxy.router_id <= 255 &&
      alltrue([for name, h in var.proxy.hosts : alltrue([for n in concat([name], h.aliases) : can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$", n))]) && contains(keys(var.vips), h.vip) && h.port >= 1 && h.port <= 65535]) &&
      length(distinct(flatten([for name, h in var.proxy.hosts : concat([name], h.aliases)]))) == length(flatten([for name, h in var.proxy.hosts : concat([name], h.aliases)])) &&
      alltrue([for c in var.proxy.clients : can(cidrhost(c, 0))]) &&
      (var.proxy.landing == null || (can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$", var.proxy.landing.name)) && !contains(flatten([for name, h in var.proxy.hosts : concat([name], h.aliases)]), var.proxy.landing.name))) &&
      (var.proxy.pve == null || (can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$", var.proxy.pve.cluster_name)) && can(regex("^[a-z0-9][a-z0-9-]*$", var.proxy.pve.node_prefix)) && !contains(flatten([for name, h in var.proxy.hosts : concat([name], h.aliases)]), var.proxy.pve.cluster_name))), false
    )
    error_message = "proxy: vip is an IPv4 address with prefix length, router_id 1..255; host keys and aliases are unique single DNS labels; every host's vip is a key in vips.auto.tfvars and port is 1..65535; clients are CIDRs; landing.name is a DNS label not used by a host; pve.cluster_name is a DNS label not used by a host and pve.node_prefix starts a DNS label."
  }
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

  # Proxmox web UIs (var.proxy.pve): host key => nginx upstream servers (node management addresses).
  proxy_pve = try(var.proxy.pve, null)
  proxy_pve_upstreams = local.proxy_pve == null ? {} : merge(
    { (local.proxy_pve.cluster_name) = {
      sticky  = true
      servers = [for name in sort(keys(var.nodes.proxmox)) : "${cidrhost(var.nodes.management_prefix, var.nodes.proxmox[name].id)}:${local.proxy_pve.port}" if !var.nodes.proxmox[name].standalone]
    } },
    { for name, n in var.nodes.proxmox : "${local.proxy_pve.node_prefix}${name}" => {
      sticky  = false
      servers = ["${cidrhost(var.nodes.management_prefix, n.id)}:${local.proxy_pve.port}"]
    } },
  )

  # Each published host: all its names (key + aliases, fully qualified) and the upstream URL. VIP hosts
  # forward over HTTP to their service VIP; Proxmox hosts over HTTPS to an nginx upstream block of nodes.
  proxy_hosts = var.proxy == null ? {} : merge(
    { for name, h in var.proxy.hosts : name => {
      names      = [for n in concat([name], h.aliases) : "${n}.${var.proxy.domain}"]
      upstream   = "http://${split("/", var.vips[h.vip].address)[0]}:${h.port}"
      backend    = "${h.vip}:${h.port}"
      vip        = h.vip
      websockets = h.websockets
      max_body   = h.max_body
      servers    = []
      sticky     = false
      tls        = false
    } },
    { for name, u in local.proxy_pve_upstreams : name => {
      names      = ["${name}.${var.proxy.domain}"]
      upstream   = "https://${replace(name, "-", "_")}"
      backend    = "Proxmox ${join(", ", u.servers)}"
      vip        = null
      websockets = true
      max_body   = local.proxy_pve.max_body
      servers    = u.servers
      sticky     = u.sticky
      tls        = true
    } },
  )

  # Landing page: its names and the generated index of the published hosts.
  proxy_landing_names = try(["${var.proxy.landing.name}.${var.proxy.domain}"], [])
  proxy_index_html = var.proxy == null || var.proxy.landing == null ? "" : templatefile("${path.module}/templates/proxy-index.html.tftpl", {
    title = var.proxy.landing.title
    hosts = [for name in sort(keys(local.proxy_hosts)) : {
      url     = "https://${local.proxy_hosts[name].names[0]}/"
      name    = local.proxy_hosts[name].names[0]
      aliases = slice(local.proxy_hosts[name].names, 1, length(local.proxy_hosts[name].names))
      backend = local.proxy_hosts[name].backend
    }]
  })

  # NetBox's CSRF_TRUSTED_ORIGINS (netbox.tf): the proxied names that forward to NetBox's VIP.
  netbox_proxy_origins = var.netbox == null ? [] : sort(flatten([
    for h in values(local.proxy_hosts) : [for n in h.names : "https://${n}"] if h.vip != null && try(var.vips[h.vip].address, null) == var.netbox.vip
  ]))

  proxy_conf_dir = "/etc/nginx-proxy" # mounted read-only into the container at the same path

  # Rendered twice: the config id (/healthz) is a hash of the config without it.
  proxy_nginx_vars = var.proxy == null ? null : {
    domain        = var.proxy.domain
    cert_dir      = var.proxy.cert_dir
    conf_dir      = local.proxy_conf_dir
    hosts         = local.proxy_hosts
    landing_names = local.proxy_landing_names
  }
  proxy_config_id  = var.proxy == null ? "" : substr(sha256(templatefile("${path.module}/templates/proxy-nginx.conf.tftpl", merge(local.proxy_nginx_vars, { config_id = "" }))), 0, 16)
  proxy_nginx_conf = var.proxy == null ? "" : templatefile("${path.module}/templates/proxy-nginx.conf.tftpl", merge(local.proxy_nginx_vars, { config_id = local.proxy_config_id }))

  proxy_script = var.proxy == null ? {} : {
    for name, vm in local.proxy_vms : name => templatefile("${path.module}/templates/proxy-deploy.sh.tftpl", {
      cert_dir    = var.proxy.cert_dir
      conf_dir    = local.proxy_conf_dir
      image       = var.proxy.image
      config_id   = local.proxy_config_id
      listen      = local.proxy_nics[name].service.address
      vip_address = local.proxy_vip
      peers       = [for peer, n in local.proxy_nics : n.service.address if peer != name]
      unit_b64 = base64encode(templatefile("${path.module}/templates/proxy-nginx.container.tftpl", {
        image    = var.proxy.image
        conf_dir = local.proxy_conf_dir
        cert_dir = var.proxy.cert_dir
      }))
      ha         = local.proxy_ha
      nginx_b64  = base64encode(local.proxy_nginx_conf)
      nft_b64    = base64encode(templatefile("${path.module}/templates/proxy.nft.tftpl", { clients = var.proxy.clients }))
      host_names = sort(concat(flatten([for h in values(local.proxy_hosts) : h.names]), local.proxy_landing_names))
      index_b64  = base64encode(local.proxy_index_html)
      keepalived_b64 = !local.proxy_ha ? "" : base64encode(templatefile("${path.module}/templates/proxy-keepalived.conf.tftpl", {
        host         = name
        ha_interface = local.proxy_nics[name].ha.interface
        ha_address   = local.proxy_nics[name].ha.address
        peers        = [for peer, n in local.proxy_nics : n.ha.address if peer != name]
        router_id    = var.proxy.router_id
        # Only the first election: nopreempt keeps the VIP where it is afterwards.
        priority  = name == local.proxy_names[0] ? 150 : 100
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
    { for name, h in local.proxy_hosts : "https://${h.names[0]}/" => h.upstream },
    local.proxy_vip == null ? {} : { vip = "${local.proxy_vip} (proxy-vip.lylat.space)" },
  )
}
