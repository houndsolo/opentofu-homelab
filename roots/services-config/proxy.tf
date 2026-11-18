# Reverse proxy for the lab's web UIs: nginx (Podman Quadlet container, pinned official image, host
# network; config in /etc/nginx-proxy) on every role "proxy" VM terminates
# TLS for https://<name>.lylat.space with the Let's Encrypt wildcard *.lylat.space that roots/certs
# installs in var.proxy.cert_dir, and forwards over plain HTTP either to the service's own VIP (its address
# from vips.auto.tfvars, e.g. grafana-vip) or, for active/active apps without a VIP (Nextcloud), to every
# VM of a role (an nginx upstream over their service addresses; nginx skips a node that stops answering).
# Plain TCP services (var.proxy.tcp, nginx stream: git over SSH to the Gitea VMs) are forwarded the same way.
# DNS: every host name and alias is generated as a CNAME to proxy-vip.lylat.space (dns-records.tf).
#
# A deploy that restarts nginx (new image/unit) on the node holding the VIP first hands the VIP to a
# healthy peer (stops keepalived), so the switch costs ~1 s instead of the ~9 s health-check failover.
#
# HA: both nodes run nginx all the time with the same config (stateless). keepalived holds
# var.proxy.vip on the VLAN 2 NIC of a node whose nginx answers /healthz, with use_vmac (fixed MAC,
# DT-045); adverts go unicast over the HA L2VNI (l2vnis.ha_proxy). nginx listens on all addresses,
# so the VIP needs no ip_nonlocal_bind. nftables limits 80/443 (and the TCP ports) to var.proxy.clients.
#
# Order: roots/certs first (the deploy stops if the certificate is missing). Deploys are
# canary-first: the first VM (sorted by name) must pass its health check before the others.
variable "proxy" {
  description = "Reverse proxy: published hosts (<key>.<domain> plus aliases) and the VIP + port they forward to, certificate path, proxy VIP. null = don't deploy."
  type = object({
    domain   = optional(string, "lylat.space")  # the zone; the certificate is *.<domain>
    cert_dir = optional(string, "/etc/ssl/svc") # = roots/certs var.certificate.directory
    hosts = optional(map(object({
      vip        = optional(string)           # key in vips.auto.tfvars: nginx forwards to its address
      role       = optional(string)           # or: every VM of this role (its NIC with the gateway), active/active
      port       = number                     # the service's port on that VIP / those VMs
      aliases    = optional(list(string), []) # more names in the same zone (also CNAMEs to the proxy)
      websockets = optional(bool, false)      # Upgrade/Connection headers (Grafana Live)
      max_body   = optional(string, "10m")    # client_max_body_size (uploads)
      stream     = optional(bool, false)      # no request/response buffering on the proxy, 1 h timeouts (big uploads/downloads)
      # role hosts: nginx upstream balancing. "" = round robin (the app shares sessions between nodes);
      # "hash $remote_addr consistent" = sticky per client IP (per-node sessions; ip_hash would only hash
      # the first three octets, so a whole /24 would land on one node).
      balance = optional(string, "")
      # Upstream speaks HTTPS with a certificate valid for this name (role hosts only): nginx verifies it against
      # the system CAs (the *.lylat.space wildcard on OpenBao). null = plain HTTP.
      tls_name = optional(string)
      })), {
      grafana       = { vip = "grafana-vip", port = 3000, websockets = true }
      netbox        = { vip = "netbox-vip", port = 80, max_body = "100m" }
      "dark-triage" = { vip = "dark-triage-vip", port = 80, aliases = ["triage"] }
      # Nextcloud (nextcloud.tf): nc01-03, sessions shared through Valkey, so plain round robin. With
      # nextcloud.sessions = "local" set balance = "hash $remote_addr consistent" (vault nextcloud-ha-plan).
      nextcloud = { role = "nextcloud", port = 80, max_body = "16g", stream = true }
      # Gitea (gitea.tf): git01/git02, sessions in Valkey, so plain round robin. Pushes and LFS uploads over
      # HTTPS stream through without a size limit.
      git = { role = "gitea", port = 3000, max_body = "0", stream = true }
      # arr stack (arr.tf): one VM, one host per app. Sonarr/Radarr/Prowlarr/Bazarr/Seerr use websockets for
      # live UI updates; Jellyfin streams video (no buffering, long timeouts).
      sonarr   = { role = "arr", port = 8989, websockets = true }
      radarr   = { role = "arr", port = 7878, websockets = true }
      prowlarr = { role = "arr", port = 9696, websockets = true }
      bazarr   = { role = "arr", port = 6767, websockets = true }
      jellyfin = { role = "arr", port = 8096, websockets = true, stream = true, max_body = "100m" }
      seerr    = { role = "arr", port = 5055, websockets = true }
      # OpenBao (openbao.tf): bao01-03, TLS end to end (verified), any node answers (standbys forward).
      bao = { role = "bao", port = 8200, tls_name = "bao.lylat.space" }
    })
    # Plain TCP forwards (nginx stream), name => listen port on every proxy (clients use proxy-vip) and every
    # VM of a role on target_port. Clients must name the port; 22 stays the proxies' own sshd.
    tcp = optional(map(object({
      port        = number
      role        = string
      target_port = number
      })), {
      # git over SSH to Gitea's built-in SSH server: ssh://git@git.lylat.space:2222/<owner>/<repo>.git
      git-ssh = { port = 2222, role = "gitea", target_port = 2222 }
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
      alltrue([for name, h in var.proxy.hosts : alltrue([for n in concat([name], h.aliases) : can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$", n))]) && (h.vip == null) != (h.role == null) && (h.vip == null || contains(keys(var.vips), coalesce(h.vip, "-"))) && h.port >= 1 && h.port <= 65535 && contains(["", "ip_hash", "least_conn", "hash $remote_addr consistent"], h.balance)]) &&
      length(distinct(flatten([for name, h in var.proxy.hosts : concat([name], h.aliases)]))) == length(flatten([for name, h in var.proxy.hosts : concat([name], h.aliases)])) &&
      alltrue([for c in var.proxy.clients : can(cidrhost(c, 0))]) &&
      alltrue([for name, t in var.proxy.tcp : can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$", name)) && t.port >= 1 && t.port <= 65535 && !contains([22, 80, 443], t.port) && t.target_port >= 1 && t.target_port <= 65535]) &&
      length(distinct([for t in values(var.proxy.tcp) : t.port])) == length(var.proxy.tcp) &&
      (var.proxy.landing == null || (can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$", var.proxy.landing.name)) && !contains(flatten([for name, h in var.proxy.hosts : concat([name], h.aliases)]), var.proxy.landing.name))) &&
      (var.proxy.pve == null || (can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$", var.proxy.pve.cluster_name)) && can(regex("^[a-z0-9][a-z0-9-]*$", var.proxy.pve.node_prefix)) && !contains(flatten([for name, h in var.proxy.hosts : concat([name], h.aliases)]), var.proxy.pve.cluster_name))), false
    )
    error_message = "proxy: vip is an IPv4 address with prefix length, router_id 1..255; host keys and aliases are unique single DNS labels; every host has either a vip (a key in vips.auto.tfvars) or a role, port 1..65535, balance \"\", \"ip_hash\", \"least_conn\" or \"hash $remote_addr consistent\"; clients are CIDRs; tcp names are DNS labels with unique ports other than 22/80/443; landing.name is a DNS label not used by a host; pve.cluster_name is a DNS label not used by a host and pve.node_prefix starts a DNS label."
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

  # Role hosts (active/active apps, no VIP): host key => the role's VMs' service addresses (the NIC with
  # the gateway) and the port. A role without VMs (yet) publishes nothing (check proxy_role_hosts_have_vms).
  proxy_role_servers = var.proxy == null ? {} : {
    for name, h in var.proxy.hosts : name => [
      for vm_name in sort([for n, vm in var.vms : n if vm.owner == "services-vms" && vm.role == h.role]) :
      "${split("/", one([for nic in var.vms[vm_name].network_devices : nic.ipv4_address if nic.ipv4_address != null && nic.ipv4_gateway != null]))[0]}:${h.port}"
    ] if h.role != null
  }

  # TCP forwards (var.proxy.tcp): name => listen port and the role's VMs' service addresses. A role without
  # VMs (yet) forwards nothing.
  proxy_tcp = var.proxy == null ? {} : {
    for name, t in var.proxy.tcp : name => {
      port = t.port
      servers = [
        for vm_name in sort([for n, vm in var.vms : n if vm.owner == "services-vms" && vm.role == t.role]) :
        "${split("/", one([for nic in var.vms[vm_name].network_devices : nic.ipv4_address if nic.ipv4_address != null && nic.ipv4_gateway != null]))[0]}:${t.target_port}"
      ]
      backend = "${t.role} VMs :${t.target_port}"
    }
  }
  proxy_tcp_live = { for name, t in local.proxy_tcp : name => t if length(t.servers) > 0 }

  # Proxmox web UIs (var.proxy.pve): host key => nginx upstream servers (node management addresses).
  proxy_pve = try(var.proxy.pve, null)
  proxy_pve_upstreams = local.proxy_pve == null ? {} : merge(
    { (local.proxy_pve.cluster_name) = {
      balance = "ip_hash" # one browser stays on one node (noVNC/xterm.js consoles); a failed node moves it to the next
      servers = [for name in sort(keys(var.nodes.proxmox)) : "${cidrhost(var.nodes.management_prefix, var.nodes.proxmox[name].id)}:${local.proxy_pve.port}" if !var.nodes.proxmox[name].standalone]
    } },
    { for name, n in var.nodes.proxmox : "${local.proxy_pve.node_prefix}${name}" => {
      balance = ""
      servers = ["${cidrhost(var.nodes.management_prefix, n.id)}:${local.proxy_pve.port}"]
    } },
  )

  # Each published host: all its names (key + aliases, fully qualified) and the upstream URL. VIP hosts
  # forward over HTTP to their service VIP; role hosts over HTTP and Proxmox hosts over HTTPS to an nginx
  # upstream block of their servers.
  proxy_hosts = var.proxy == null ? {} : merge(
    { for name, h in var.proxy.hosts : name => {
      names      = [for n in concat([name], h.aliases) : "${n}.${var.proxy.domain}"]
      upstream   = "http://${split("/", var.vips[h.vip].address)[0]}:${h.port}"
      backend    = "${h.vip}:${h.port}"
      vip        = h.vip
      websockets = h.websockets
      max_body   = h.max_body
      stream     = h.stream
      servers    = []
      balance    = ""
      tls        = false
      tls_name   = null
    } if h.vip != null },
    { for name, h in var.proxy.hosts : name => {
      names      = [for n in concat([name], h.aliases) : "${n}.${var.proxy.domain}"]
      upstream   = "${h.tls_name != null ? "https" : "http"}://${replace(name, "-", "_")}"
      backend    = "${h.role} VMs ${join(", ", local.proxy_role_servers[name])}${h.tls_name != null ? " (https)" : ""}"
      vip        = null
      websockets = h.websockets
      max_body   = h.max_body
      stream     = h.stream
      servers    = local.proxy_role_servers[name]
      balance    = h.balance
      tls        = false
      tls_name   = h.tls_name
    } if h.role != null && length(try(local.proxy_role_servers[name], [])) > 0 },
    { for name, u in local.proxy_pve_upstreams : name => {
      names      = ["${name}.${var.proxy.domain}"]
      upstream   = "https://${replace(name, "-", "_")}"
      backend    = "Proxmox ${join(", ", u.servers)}"
      vip        = null
      websockets = true
      max_body   = local.proxy_pve.max_body
      stream     = false
      servers    = u.servers
      balance    = u.balance
      tls        = true
      tls_name   = null
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
    tcp           = local.proxy_tcp_live
    landing_names = local.proxy_landing_names
  }
  proxy_config_id  = var.proxy == null ? "" : substr(sha256(templatefile("${path.module}/templates/proxy-nginx.conf.tftpl", merge(local.proxy_nginx_vars, { config_id = "" }))), 0, 16)
  proxy_nginx_conf = var.proxy == null ? "" : templatefile("${path.module}/templates/proxy-nginx.conf.tftpl", merge(local.proxy_nginx_vars, { config_id = local.proxy_config_id }))

  # The deploy (modules/services/quadlet-deploy). The nginx config is tested with the same image against the
  # certificate before anything is installed; a config change reloads nginx (ExecReload, graceful), a unit
  # change restarts it (after handing the VIP to a healthy peer, templates/proxy-vip-handoff.sh.tftpl). The
  # landing page is static (no reload). Afterwards: /healthz reports this config's id, and every published
  # name answers over TLS on this node.
  proxy_files = {
    for name, vm in(var.proxy == null ? {} : local.proxy_vms) : name => concat([
      # nftables: own table, loaded by its own unit (the distro nftables.service stays as it is).
      { path = "/etc/nftables-proxy.nft", units = ["proxy-nft"], content = templatefile("${path.module}/templates/proxy.nft.tftpl", { clients = var.proxy.clients, ports = concat([80, 443], sort([for t in values(local.proxy_tcp_live) : t.port])) }) },
      { path = "/etc/systemd/system/proxy-nft.service", units = ["proxy-nft"], content = file("${path.module}/templates/proxy-nft.service") },
      { path = "/etc/containers/systemd/nginx.container", units = ["nginx"], content = templatefile("${path.module}/templates/proxy-nginx.container.tftpl", {
        image    = local.container_images.nginx
        conf_dir = local.proxy_conf_dir
        cert_dir = var.proxy.cert_dir
      }) },
      { path = "${local.proxy_conf_dir}/nginx.conf", units = ["nginx"], content = local.proxy_nginx_conf },
      { path = "${local.proxy_conf_dir}/www/index.html", content = local.proxy_index_html },
      ], [for f in [
        { path = "/usr/local/sbin/proxy-vip-handoff", mode = "0755", content = templatefile("${path.module}/templates/proxy-vip-handoff.sh.tftpl", {
          vip_address = local.proxy_vip
          peers       = [for peer, n in local.proxy_nics : n.service.address if peer != name]
        }) },
        { path = "/etc/keepalived/keepalived.conf", mode = "0600", units = ["keepalived"], content = templatefile("${path.module}/templates/proxy-keepalived.conf.tftpl", {
          host         = name
          ha_interface = local.proxy_nics[name].ha.interface
          ha_address   = local.proxy_nics[name].ha.address
          peers        = [for peer, n in local.proxy_nics : n.ha.address if peer != name]
          router_id    = var.proxy.router_id
          # Only the first election: nopreempt keeps the VIP where it is afterwards.
          priority  = name == local.proxy_names[0] ? 150 : 100
          vip       = var.proxy.vip
          interface = local.proxy_nics[name].service.interface
        }) },
        # enable_script_security: the check must be root-owned and not writable by others.
        { path = "/etc/keepalived/chk_proxy.sh", mode = "0755", units = ["keepalived"], content = templatefile("${path.module}/templates/proxy-keepalived-check.sh.tftpl", {
          url = "http://127.0.0.1/healthz"
        }) },
    ] : f if local.proxy_ha])
  }
  proxy_host_names = var.proxy == null ? [] : sort(concat(flatten([for h in values(local.proxy_hosts) : h.names]), local.proxy_landing_names))

  # Canary first: the first VM by name, then everything else (depends_on).
  proxy_canary = { for name, f in local.proxy_files : name => f if name == local.proxy_names[0] }
  proxy_rest   = { for name, f in local.proxy_files : name => f if name != local.proxy_names[0] }
}

module "proxy" {
  source   = "../../modules/services/quadlet-deploy"
  for_each = local.proxy_files

  name     = "proxy"
  host     = each.key
  files    = each.value
  units    = concat(["proxy-nft", "nginx"], local.proxy_ha ? ["keepalived"] : [])
  images   = [local.container_images.nginx]
  packages = concat(["podman", "nftables", "curl"], local.proxy_ha ? ["keepalived"] : [])
  dirs     = [{ path = local.proxy_conf_dir }, { path = "${local.proxy_conf_dir}/www" }]
  # The certificate comes from roots/certs; without it nginx can't start.
  setup = ["for f in '${var.proxy.cert_dir}/fullchain.pem' '${var.proxy.cert_dir}/privkey.pem'; do [ -s \"$f\" ] || { echo \"missing $f: apply roots/certs first\" >&2; exit 1; }; done"]
  checks = concat([
    "nft -c -f \"$stage/etc/nftables-proxy.nft\"",
    "podman run --rm --network none --entrypoint nginx -v \"$stage${local.proxy_conf_dir}:${local.proxy_conf_dir}:ro\" -v '${var.proxy.cert_dir}:${var.proxy.cert_dir}:ro' '${local.container_images.nginx}' -c '${local.proxy_conf_dir}/nginx.conf' -t -q",
  ], local.proxy_ha ? ["keepalived -t -f \"$stage/etc/keepalived/keepalived.conf\""] : [])
  pre_install  = local.proxy_ha ? ["bash \"$stage/usr/local/sbin/proxy-vip-handoff\" \"$stage\""] : []
  post_install = concat(["systemctl enable --quiet proxy-nft.service"], local.proxy_ha ? ["systemctl enable --quiet keepalived.service"] : [])
  verify = concat([
    # A reload is graceful: old workers keep answering for a moment. This config's id, twice in a row.
    "retry sh -c \"curl -sf --max-time 2 http://127.0.0.1/healthz | grep -qx 'ok ${local.proxy_config_id}' && sleep 0.5 && curl -sf --max-time 2 http://127.0.0.1/healthz | grep -qx 'ok ${local.proxy_config_id}'\"",
    ], [
    # Every published name answers over TLS on this node (any HTTP status: the upstream decides).
    for h in local.proxy_host_names : "curl -sS -o /dev/null --max-time 5 --resolve '${h}:443:${local.proxy_nics[each.key].service.address}' -w 'https://${h}/ on ${local.proxy_nics[each.key].service.address}: HTTP %%{http_code}\\n' 'https://${h}/'"
    ], [
    # Every TCP forward listens on this node (the upstream may still be down).
    for name, t in local.proxy_tcp_live : "timeout 5 bash -c 'exec 3<>/dev/tcp/${local.proxy_nics[each.key].service.address}/${t.port}' && echo 'tcp ${name} :${t.port} on ${local.proxy_nics[each.key].service.address}: listening'"
  ])
}

check "proxy_tcp_have_vms" {
  assert {
    condition     = length(local.proxy_tcp_live) == length(local.proxy_tcp)
    error_message = "proxy: TCP forwards without any VM of their role aren't published (yet): ${join(", ", [for name, t in local.proxy_tcp : name if length(t.servers) == 0])}."
  }
}

check "proxy_role_hosts_have_vms" {
  assert {
    condition     = var.proxy == null || alltrue([for name, servers in local.proxy_role_servers : length(servers) > 0])
    error_message = "proxy: role hosts without any VM of that role aren't published (yet): ${join(", ", [for name, servers in local.proxy_role_servers : name if length(servers) == 0])}."
  }
}

resource "terraform_data" "proxy_canary" {
  for_each = local.proxy_canary

  triggers_replace = [
    sha256(module.proxy[each.key].script),
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
    content     = module.proxy[each.key].script
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
    sha256(module.proxy[each.key].script),
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
    content     = module.proxy[each.key].script
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
    { for name, t in local.proxy_tcp_live : "tcp ${name} :${t.port}" => join(", ", t.servers) },
    local.proxy_vip == null ? {} : { vip = "${local.proxy_vip} (proxy-vip.lylat.space)" },
  )
}
