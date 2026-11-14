# Grafana HA on its own L2VNI (l2vnis.ha_grafana, VLAN 1011): unified alerting's gossip
# (9094) and keepalived's unicast adverts. The VIP (grafana_vrrp.vip, 10.52.11.100) sits on
# the UI NIC (lylat-app, the one with the gateway); Grafana publishes :3000 on every address, so it answers there.
locals {
  grafana_names = sort(keys(var.grafana))

  # Gossip over the HA VLAN when every Grafana VM has an address there, else the backend.
  grafana_ha_ready = alltrue([for g in values(var.grafana) : g.ha_address != null])
  grafana_gossip   = { for name, g in var.grafana : name => local.grafana_ha_ready ? g.ha_address : g.backend_address }

  grafana_vrrp_enabled = var.grafana_vrrp != null && local.grafana_ha_ready && length(var.grafana) > 1
  # First election only (nopreempt): name order, 150, 100, ...
  grafana_priority = { for i, name in local.grafana_names : name => max(150 - 50 * i, 10) }

  grafana_keepalived_conf = {
    for name, g in var.grafana : name => local.grafana_vrrp_enabled ? templatefile("${path.module}/templates/grafana-keepalived.conf.tftpl", {
      host         = name
      router_id    = try(var.grafana_vrrp.router_id, 0)
      priority     = local.grafana_priority[name]
      ha_interface = try(g.interfaces.ha, "none")
      ha_address   = g.ha_address
      peers        = sort([for peer in local.grafana_names : var.grafana[peer].ha_address if peer != name])
      vips         = try([var.grafana_vrrp.vip], [])
      interface    = try(g.interfaces.vip, "none")
    }) : null
  }

  # Extra deploy.sh pieces for keepalived (empty when the VIP is off).
  grafana_ha_packages = local.grafana_vrrp_enabled ? ["keepalived"] : []
  grafana_ha_dirs     = local.grafana_vrrp_enabled ? [{ path = "/etc/keepalived", mode = "0755", owner = "root" }] : []
  grafana_ha_files = {
    for name in local.grafana_names : name => local.grafana_vrrp_enabled ? [
      { path = "/etc/keepalived/keepalived.conf", mode = "0600", owner = "root", content = local.grafana_keepalived_conf[name], restart = [], reload = ["keepalived"] },
    ] : []
  }
  grafana_ha_validations = local.grafana_vrrp_enabled ? [
    "if command -v keepalived >/dev/null; then keepalived -t -f \"$root/etc/keepalived/keepalived.conf\"; else echo \"keepalived not installed yet: config test skipped\"; fi",
  ] : []
  grafana_ha_post_install = local.grafana_vrrp_enabled ? ["systemctl enable --quiet keepalived.service"] : []
  # keepalived last: it only takes the VIP once Grafana answers.
  grafana_ha_services = local.grafana_vrrp_enabled ? ["keepalived"] : []
}
