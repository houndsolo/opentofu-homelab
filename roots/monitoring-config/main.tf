module "leaves" {
  source = "../../modules/fabric/leaves"
  fabric = var.fabric
  nodes  = var.nodes
}

locals {
  service_vms    = { for name, vm in var.vms : name => vm if vm.owner == "services-vms" }
  monitoring_vms = { for name, vm in local.service_vms : name => vm if vm.role == "monitoring" }
  grafana_vms    = { for name, vm in local.service_vms : name => vm if vm.role == "grafana" }
  dns_vms        = { for name, vm in local.service_vms : name => vm if vm.role == "dns" }
  dhcp_vms       = { for name, vm in local.service_vms : name => vm if vm.role == "dhcp" }
  logging_vms    = { for name, vm in local.service_vms : name => vm if vm.role == "logging" }
  valkey_vms     = { for name, vm in local.service_vms : name => vm if vm.role == "valkey" }
  netbox_vms     = { for name, vm in local.service_vms : name => vm if vm.role == "netbox" }
  proxy_vms      = { for name, vm in local.service_vms : name => vm if vm.role == "proxy" }
  ticketing_vms  = { for name, vm in local.service_vms : name => vm if vm.role == "ticketing" }
  # Grafana Alloy from services-config (alloy.tf) on these VMs: HTTP on the telemetry address (alloy job);
  # they push to Loki's telemetry VIP (logging-guard allows 10.55.0.0/16 on 3100).
  alloy_service_vms = merge(local.dns_vms, local.netbox_vms, local.proxy_vms, local.valkey_vms, local.ticketing_vms)
  deploy_vms        = merge(local.monitoring_vms, local.grafana_vms, local.logging_vms)

  nics = { for name, vm in local.service_vms : name => vm.network_devices == null ? [] : vm.network_devices }
  # lylat-telemetry (VLAN telemetry_vlan_id, flat 10.55.0.0/16, zone design): every service VM's scrape and log-push
  # NIC. Exporters, node_exporter and Alloy listen there; Prometheus scrapes it; Alloy pushes to the Loki telemetry VIP.
  telemetry_address = {
    for name in keys(local.service_vms) : name => try(split("/", one([
      for nic in local.nics[name] : nic.ipv4_address if nic.vlan_id == var.telemetry_vlan_id && nic.ipv4_address != null
    ]))[0], null)
  }
  telemetry_interface = {
    for name in keys(local.service_vms) : name => try(one([
      for i, nic in local.nics[name] : "eth${i + 1}" if nic.vlan_id == var.telemetry_vlan_id && nic.ipv4_address != null
    ]), null)
  }
  mgmt = { for name, vm in local.service_vms : name => try(split("/", vm.management_address)[0], null) }

  # Address on the isolated backend VLAN, and the backend VM's monitoring-network address.
  backend_address = {
    for name in keys(local.deploy_vms) : name => try(split("/", one([
      for nic in local.nics[name] : nic.ipv4_address if contains(var.backend_vlan_ids, nic.vlan_id) && nic.ipv4_address != null
    ]))[0], null)
  }
  monitoring_address = {
    for name in keys(local.monitoring_vms) : name => try(split("/", one([
      for nic in local.nics[name] : nic.ipv4_address if nic.bridge == var.monitoring_bridge && nic.ipv4_address != null
    ]))[0], null)
  }

  # Backends: the primary (Postgres, Grafana's fallback Prometheus) and the replica.
  backend_name = contains(keys(local.monitoring_vms), var.monitoring_primary) ? var.monitoring_primary : null

  # Backends: HA VLAN NIC (keepalived adverts, Alertmanager gossip) and the NICs that hold
  # the VIPs. network_devices[i] is eth<i+1>.
  monitoring_nic = {
    for name in keys(local.monitoring_vms) : name => {
      ha = try(one([
        for i, nic in local.nics[name] : { address = split("/", nic.ipv4_address)[0], interface = "eth${i + 1}" }
        if nic.vlan_id == var.monitoring_ha_vlan_id && nic.ipv4_address != null
      ]), null)
      backend = try(one([
        for i, nic in local.nics[name] : "eth${i + 1}" if contains(var.backend_vlan_ids, nic.vlan_id) && nic.ipv4_address != null
      ]), null)
      monitoring = try(one([
        for i, nic in local.nics[name] : "eth${i + 1}" if nic.bridge == var.monitoring_bridge && nic.ipv4_address != null
      ]), null)
    }
  }
  monitoring_ha_ready = alltrue([for n in values(local.monitoring_nic) : n.ha != null && n.backend != null && n.monitoring != null])

  # Grafana VMs: HA VLAN NIC (alerting gossip, VRRP) and the UI NIC (the one with the
  # default gateway, VLAN 2) that holds the VIP. network_devices[i] is eth<i+1>.
  grafana_nic = {
    for name in keys(local.grafana_vms) : name => {
      ha = try(one([
        for i, nic in local.nics[name] : { address = split("/", nic.ipv4_address)[0], interface = "eth${i + 1}" }
        if nic.vlan_id == var.grafana_ha_vlan_id && nic.ipv4_address != null
      ]), null)
      ui = try(one([
        for i, nic in local.nics[name] : "eth${i + 1}" if nic.ipv4_address != null && nic.ipv4_gateway != null
      ]), null)
    }
  }

  # Logging VMs: address and interface name per network. The management NIC is eth0 and
  # network_devices[i] is eth<i+1> (the order Proxmox attaches them; checked with ip -br a).
  logging_nic = {
    for name in keys(local.logging_vms) : name => {
      ha = try(one([
        for i, nic in local.nics[name] : { address = split("/", nic.ipv4_address)[0], interface = "eth${i + 1}" }
        if nic.vlan_id == var.ha_vlan_id && nic.ipv4_address != null
      ]), null)
      backend = try(one([
        for i, nic in local.nics[name] : { address = split("/", nic.ipv4_address)[0], interface = "eth${i + 1}" }
        if contains(var.backend_vlan_ids, nic.vlan_id) && nic.ipv4_address != null
      ]), null)
      monitoring = try(one([
        for i, nic in local.nics[name] : { address = split("/", nic.ipv4_address)[0], interface = "eth${i + 1}" }
        if nic.bridge == var.monitoring_bridge && nic.ipv4_address != null
      ]), null)
      mgmt = local.mgmt[name] == null ? null : { address = local.mgmt[name], interface = "eth0" }
    }
  }
  logging_ready = alltrue([for name, n in local.logging_nic : n.ha != null && n.backend != null && n.monitoring != null && n.mgmt != null])

  # Syslog senders' address => host label, so logs and metrics share the host value:
  # every SNMP target (switches, WLCs; they log from the same 10.5 address), then
  # logging_settings.syslog_host_overrides.
  syslog_host_overrides = merge(
    merge([for job in var.snmp_targets : { for host, address in job.targets : address => host }]...),
    var.logging_settings.syslog_host_overrides,
  )

  pve_prefix = try(var.pve_network.bridges[var.pve_monitoring_bridge].ipv4.cidrhost_prefix, null)
  # Cluster nodes only: the standalone host would need its own API token.
  pve_nodes = {
    for name, node in var.nodes.proxmox : name => cidrhost(local.pve_prefix, node.id)
    if local.pve_prefix != null
  }

  targets = {
    node = concat(
      # Service VMs: their telemetry address (falls back to the old one while a VM has no telemetry NIC).
      [for name in keys(local.monitoring_vms) : { host = name, address = coalesce(local.telemetry_address[name], local.monitoring_address[name], "0.0.0.0"), labels = { role = "monitoring" } }],
      [for name in keys(local.grafana_vms) : { host = name, address = coalesce(local.telemetry_address[name], local.backend_address[name], "0.0.0.0"), labels = { role = "grafana" } }],
      [for name in keys(local.dns_vms) : { host = name, address = coalesce(local.telemetry_address[name], local.mgmt[name]), labels = { role = "dns" } }],
      [for name in keys(local.valkey_vms) : { host = name, address = coalesce(local.telemetry_address[name], local.mgmt[name]), labels = { role = "valkey" } }],
      [for name in keys(local.netbox_vms) : { host = name, address = coalesce(local.telemetry_address[name], local.mgmt[name]), labels = { role = "netbox" } }],
      [for name in keys(local.proxy_vms) : { host = name, address = coalesce(local.telemetry_address[name], local.mgmt[name]), labels = { role = "proxy" } }],
      [for name in keys(local.ticketing_vms) : { host = name, address = coalesce(local.telemetry_address[name], local.mgmt[name]), labels = { role = "ticketing" } }],
      [for name in keys(local.logging_vms) : { host = name, address = coalesce(local.telemetry_address[name], local.backend_address[name], "0.0.0.0"), labels = { role = "logging" } }],
      [for name, n in local.metrics_nic : { host = name, address = coalesce(local.telemetry_address[name], try(n.backend.address, "0.0.0.0")), labels = { role = "metrics" } } if local.mimir_enabled],
      [for name, n in local.postgres_nic : { host = name, address = coalesce(local.telemetry_address[name], try(n.backend.address, "0.0.0.0")), labels = { role = "postgres" } } if local.postgres_enabled],
      [for name, address in local.pve_nodes : { host = name, address = address, labels = { role = "proxmox" } }],
      [for host, address in var.node_extra_targets : { host = host, address = address, labels = {} }],
    )
    vyos = concat(
      [for name, leaf in module.leaves.leaves : {
        host = "leaf-${leaf.id}", address = cidrhost(var.fabric.settings.management_prefix, leaf.id), labels = { role = "leaf" }
      }],
      [for name in keys(local.dhcp_vms) : { host = name, address = local.mgmt[name], labels = { role = "dhcp" } }],
      [for host, address in var.vyos_extra_targets : { host = host, address = address, labels = { role = "router" } }],
    )
    pve      = [for name, address in local.pve_nodes : { host = name, address = address } if !var.nodes.proxmox[name].standalone]
    grafana  = [for name in keys(local.grafana_vms) : { host = name, address = coalesce(local.backend_address[name], "0.0.0.0") }]
    telegraf = [for host, address in var.vyos_telegraf_targets : { host = host, address = address }]
    ceph     = [for name in var.ceph_mgr_nodes : { host = name, address = local.pve_nodes[name] } if contains(keys(local.pve_nodes), name)]
    # Exporters from services-config (valkey-monitoring.tf, proxy-monitoring.tf, alloy.tf, dns-bind-exporter.tf)
    # listen on the VM's telemetry address (services-config local.scrape_ip; mgmt while a VM has no telemetry NIC).
    valkey = [for name in sort(keys(local.valkey_vms)) : { host = name, address = coalesce(local.telemetry_address[name], local.mgmt[name]) }]
    nginx  = [for name in sort(keys(local.proxy_vms)) : { host = name, address = coalesce(local.telemetry_address[name], local.mgmt[name]) }]
    alloy  = [for name in sort(keys(local.alloy_service_vms)) : { host = name, address = coalesce(local.telemetry_address[name], local.mgmt[name]) }]
    bind   = [for name in sort(keys(local.dns_vms)) : { host = name, address = coalesce(local.telemetry_address[name], local.mgmt[name]) }]
    # NetBox's /metrics (django-prometheus) on each node's own service address (the NIC with the
    # default gateway; port 80 is published there), not the VIP, so each node is scraped.
    netbox = [for name in sort(keys(local.netbox_vms)) : {
      host = name
      address = split("/", one([
        for nic in local.nics[name] : nic.ipv4_address if nic.ipv4_address != null && nic.ipv4_gateway != null
      ]))[0]
    }]
    snmp = var.snmp_targets
    blackbox = {
      icmp     = [for host, address in var.blackbox_icmp_targets : { host = host, target = address }]
      http_2xx = [for host, url in var.blackbox_http_targets : { host = host, target = url }]
      https    = [for host, url in var.blackbox_https_targets : { host = host, target = url }]
      dns_soa = [
        for name in keys(local.dns_vms) : {
          host = name
          # The service address: the NIC with the default gateway (the HA NIC has none).
          target = split("/", one([
            for nic in local.nics[name] : nic.ipv4_address if nic.ipv4_address != null && nic.ipv4_gateway != null
          ]))[0]
        }
      ]
    }
  }
}

resource "random_password" "grafana_db" {
  length  = 32
  special = false
}

resource "random_password" "grafana_admin" {
  length  = 24
  special = false
}

resource "random_password" "grafana_secret_key" {
  length  = 40
  special = false
}

module "monitoring" {
  source = "../../modules/services/monitoring"

  # Every role = "monitoring" VM; Postgres on monitoring_primary.
  backends = {
    for name, n in local.monitoring_nic : name => {
      monitoring_address = coalesce(local.monitoring_address[name], "0.0.0.0")
      backend_address    = coalesce(local.backend_address[name], "0.0.0.0")
      telemetry_address  = local.telemetry_address[name]
      ha_address         = try(n.ha.address, null)
      interfaces         = local.monitoring_ha_ready ? { ha = n.ha.interface, backend = n.backend, monitoring = n.monitoring } : null
    }
  }
  primary_backend = coalesce(local.backend_name, var.monitoring_primary)
  backend_vrrp = var.backend_vrrp == null ? null : {
    vips      = var.backend_vrrp.vips
    router_id = var.backend_vrrp.router_id
  }
  grafana = {
    for name, n in local.grafana_nic : name => {
      backend_address   = coalesce(local.backend_address[name], "0.0.0.0")
      telemetry_address = local.telemetry_address[name]
      ha_address        = try(n.ha.address, null)
      interfaces        = n.ha == null || n.ui == null ? null : { ha = n.ha.interface, vip = n.ui }
    }
  }
  grafana_vrrp = var.grafana_vrrp == null ? null : {
    vip       = var.grafana_vrrp.vip
    router_id = var.grafana_vrrp.router_id
  }
  images   = var.images
  targets  = local.targets
  settings = var.settings
  secrets = {
    grafana_db_password    = random_password.grafana_db.result
    grafana_admin_password = coalesce(var.grafana_admin_password, random_password.grafana_admin.result)
    grafana_secret_key     = random_password.grafana_secret_key.result
  }
  pve_exporter_token = var.pve_exporter_token
  snmp_auths         = var.snmp_v3_auths

  # pve-metrics.tf: the PVE metric servers' writes into Prometheus.
  pvestatd       = var.pve_metrics.enabled ? { port = var.pve_metrics.pvestatd_port } : null
  pvestatd_token = random_password.pvestatd.result

  # Telegraf for the C9800 telemetry (wlc_* -> Prometheus) on every backend; the WLCs send to the
  # monitoring VIP, so only its holder receives.
  wlc_telemetry = var.wlc_telemetry == null ? null : {
    port     = var.wlc_telemetry.port
    backends = sort(keys(local.monitoring_vms))
  }

  # Unaddressed networks become 0.0.0.0 here and fail terraform_data.logging's precondition.
  logging = {
    for name, n in local.logging_nic : name => {
      ha_address         = try(n.ha.address, "0.0.0.0")
      backend_address    = try(n.backend.address, "0.0.0.0")
      monitoring_address = try(n.monitoring.address, "0.0.0.0")
      telemetry_address  = local.telemetry_address[name]
      interfaces = {
        ha         = try(n.ha.interface, "none")
        backend    = try(n.backend.interface, "none")
        monitoring = try(n.monitoring.interface, "none")
        telemetry  = local.telemetry_interface[name]
      }
    }
  }
  logging_settings = merge(var.logging_settings, {
    syslog_host_overrides = local.syslog_host_overrides
  })
  logging_secrets = var.loki_s3 == null ? null : {
    s3_bucket     = var.loki_s3.bucket
    s3_access_key = var.loki_s3.access_key
    s3_secret_key = var.loki_s3.secret_key
  }

  # metrics.tf: Mimir on the role = "metrics" VMs, once the RGW keys are set.
  metrics = {
    for name, n in local.metrics_nic : name => {
      ha_address        = try(n.ha.address, "0.0.0.0")
      backend_address   = try(n.backend.address, "0.0.0.0")
      telemetry_address = local.telemetry_address[name]
      interfaces        = { ha = try(n.ha.interface, "none"), backend = try(n.backend.interface, "none") }
    }
  }
  metrics_settings = var.metrics_settings
  metrics_secrets = var.mimir_s3 == null ? null : {
    s3_bucket     = var.mimir_s3.bucket
    s3_access_key = var.mimir_s3.access_key
    s3_secret_key = var.mimir_s3.secret_key
  }

  # postgres.tf: the Patroni cluster on the role = "postgres" VMs, once the RGW keys are set.
  postgres = {
    for name, n in local.postgres_nic : name => {
      ha_address        = try(n.ha.address, "0.0.0.0")
      backend_address   = try(n.backend.address, "0.0.0.0")
      telemetry_address = local.telemetry_address[name]
      interfaces        = { ha = try(n.ha.interface, "none"), backend = try(n.backend.interface, "none") }
    }
  }
  postgres_settings = var.postgres_settings
  # Application databases (role = database = key): dark-triage (role "ticketing" VMs) and NetBox
  # (role "netbox" VMs) connect from their backend VLAN addresses with the shared passwords from
  # app-db.secret.auto.tfvars.
  postgres_apps = {
    for app, clients in local.postgres_app_clients : app => {
      clients        = clients
      grafana_grants = contains(keys(var.app_db_passwords), "${app}_grafana") ? lookup(local.postgres_app_grafana_grants, app, []) : []
    } if length(clients) > 0 && contains(keys(var.app_db_passwords), app)
  }
  postgres_app_passwords = var.app_db_passwords
  postgres_secrets = var.postgres_s3 == null ? null : {
    s3_bucket            = var.postgres_s3.bucket
    s3_access_key        = var.postgres_s3.access_key
    s3_secret_key        = var.postgres_s3.secret_key
    superuser_password   = random_password.pg_superuser.result
    replication_password = random_password.pg_replication.result
    restapi_password     = random_password.pg_restapi.result
    monitor_password     = random_password.pg_monitor.result
  }
  rgw_bucket_alerts = var.rgw_bucket_alerts # pve-collectors/rgw-bucket-stats.py
}

resource "terraform_data" "backend" {
  for_each = local.monitoring_vms

  triggers_replace = [
    sha256(module.monitoring.backend_deployments[each.key]),
    each.value.management_address,
    each.value.vm_id,
    each.value.config.ssh_username,
    var.deploy_revision,
  ]

  lifecycle {
    precondition {
      condition     = local.backend_name != null && length(local.monitoring_vms) <= 2
      error_message = "Define one or two services-vms VMs with role = \"monitoring\", one of them named by monitoring_primary (\"${var.monitoring_primary}\")."
    }
    precondition {
      condition     = var.backend_vrrp == null || length(local.monitoring_vms) < 2 || local.monitoring_ha_ready
      error_message = "With two backends and backend_vrrp, every monitoring VM needs one addressed NIC on VLAN ${var.monitoring_ha_vlan_id} (ha_monitor)."
    }
    precondition {
      condition     = local.backend_address[each.key] != null && local.monitoring_address[each.key] != null
      error_message = "The monitoring VM needs one addressed NIC on VLAN ${join("/", var.backend_vlan_ids)} and one on ${var.monitoring_bridge}."
    }
    precondition {
      condition     = alltrue([for name in keys(local.grafana_vms) : local.backend_address[name] != null])
      error_message = "Every grafana VM needs one addressed NIC on VLAN ${join("/", var.backend_vlan_ids)}."
    }
    precondition {
      condition     = local.pve_prefix != null
      error_message = "pve_network.bridges[\"${var.pve_monitoring_bridge}\"].ipv4.cidrhost_prefix is not set."
    }
  }

  connection {
    type        = "ssh"
    host        = split("/", each.value.management_address)[0]
    user        = each.value.config.ssh_username
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = ["install -d -m 0700 /tmp/tofu-monitoring-${self.id}"]
  }

  provisioner "file" {
    content     = module.monitoring.backend_deployments[each.key]
    destination = "/tmp/tofu-monitoring-${self.id}/deploy.sh"
  }

  provisioner "remote-exec" {
    inline = [
      # One command, so a failed deploy fails the apply (remote-exec reports the last exit status).
      "rc=0; sudo -n bash /tmp/tofu-monitoring-${self.id}/deploy.sh deploy || rc=$?; rm -rf /tmp/tofu-monitoring-${self.id}; exit $rc",
    ]
  }
}

resource "terraform_data" "grafana" {
  for_each = local.grafana_vms

  # Grafana needs Postgres (mon01's, or the Patroni cluster after the cutover) and the datasources on the backend.
  # Its "prometheus" datasource points at Mimir once mimir_s3 is set: wait for a healthy Mimir (metrics.tf).
  depends_on = [terraform_data.backend, terraform_data.postgres, terraform_data.metrics]

  triggers_replace = [
    sha256(module.monitoring.grafana_deployments[each.key]),
    each.value.management_address,
    each.value.vm_id,
    each.value.config.ssh_username,
    var.deploy_revision,
  ]

  lifecycle {
    precondition {
      condition     = local.backend_address[each.key] != null
      error_message = "${each.key} needs one addressed NIC on VLAN ${join("/", var.backend_vlan_ids)}."
    }
    precondition {
      condition     = var.grafana_vrrp == null || (local.grafana_nic[each.key].ha != null && local.grafana_nic[each.key].ui != null)
      error_message = "${each.key} needs one addressed NIC on VLAN ${var.grafana_ha_vlan_id} (Grafana HA) and one with a default gateway (UI, holds the VIP) for grafana_vrrp."
    }
  }

  connection {
    type        = "ssh"
    host        = split("/", each.value.management_address)[0]
    user        = each.value.config.ssh_username
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = ["install -d -m 0700 /tmp/tofu-grafana-${self.id}"]
  }

  provisioner "file" {
    content     = module.monitoring.grafana_deployments[each.key]
    destination = "/tmp/tofu-grafana-${self.id}/deploy.sh"
  }

  provisioner "remote-exec" {
    inline = [
      # One command, so a failed deploy fails the apply (remote-exec reports the last exit status).
      "rc=0; sudo -n bash /tmp/tofu-grafana-${self.id}/deploy.sh deploy || rc=$?; rm -rf /tmp/tofu-grafana-${self.id}; exit $rc",
    ]
  }
}

# One per logging VM. They all deploy at once; for a rolling restart (one Loki at a
# time, each waiting for /ready) apply with -parallelism=1. See the README.
resource "terraform_data" "logging" {
  for_each = local.logging_vms

  # Alertmanager (ruler) and the backend VLAN must be up; Alloy on mon01/graf pushes to the VIP.
  depends_on = [terraform_data.backend]

  triggers_replace = [
    sha256(module.monitoring.logging_deployments[each.key]),
    each.value.management_address,
    each.value.vm_id,
    each.value.config.ssh_username,
    var.deploy_revision,
  ]

  lifecycle {
    precondition {
      condition     = var.loki_s3 != null
      error_message = "Set loki_s3 = { bucket, access_key, secret_key } (the RGW user for Loki) in roots/monitoring-config/logging.secret.auto.tfvars."
    }
    precondition {
      condition     = local.logging_ready
      error_message = "Every logging VM needs a management address and one addressed NIC each on the HA VLAN ${var.ha_vlan_id}, VLAN ${join("/", var.backend_vlan_ids)} and ${var.monitoring_bridge}."
    }
    precondition {
      condition     = length(local.logging_vms) >= var.logging_settings.replication_factor
      error_message = "Loki's replication_factor (${var.logging_settings.replication_factor}) needs at least that many logging VMs."
    }
  }

  connection {
    type        = "ssh"
    host        = split("/", each.value.management_address)[0]
    user        = each.value.config.ssh_username
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = ["install -d -m 0700 /tmp/tofu-logging-${self.id}"]
  }

  provisioner "file" {
    content     = module.monitoring.logging_deployments[each.key]
    destination = "/tmp/tofu-logging-${self.id}/deploy.sh"
  }

  provisioner "remote-exec" {
    inline = [
      # One command, so a failed deploy fails the apply (remote-exec reports the last exit status).
      "rc=0; sudo -n bash /tmp/tofu-logging-${self.id}/deploy.sh deploy || rc=$?; rm -rf /tmp/tofu-logging-${self.id}; exit $rc",
    ]
  }
}
