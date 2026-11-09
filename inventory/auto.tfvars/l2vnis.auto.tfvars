# Standalone L2VNIs for HA peer traffic: no VRF, no anycast gateway, no DHCP.
# VLAN = VNI - 9000. VIPs stay on the client-facing NICs; only unicast peer traffic
# (keepalived adverts, Kea HA, Loki memberlist/gRPC, Grafana alerting HA) uses these.
l2vnis = {
  ha_dhcp = {
    vni         = 9211
    vlan_id     = 211
    prefix      = "10.21.67.0/24"
    description = "DHCP Kea HA heartbeat (dhcp01 .1, dhcp02 .2)"
  }
  ha_dns = {
    vni         = 9212
    vlan_id     = 212
    prefix      = "10.21.53.0/24"
    description = "DNS keepalived (dns01 .1, dns02 .2; VIP 10.8.53.53 on VLAN 8)"
  }
  ha_grafana = {
    vni         = 9213
    vlan_id     = 213
    prefix      = "10.21.11.0/24"
    description = "Grafana keepalived + alerting HA (graf01 .31, graf02 .32; VIP 10.2.11.40 on VLAN 2)"
  }
  ha_logging = {
    vni         = 9214
    vlan_id     = 214
    prefix      = "10.21.12.0/24"
    description = "Loki memberlist/gRPC + keepalived (log01-03 .33-.35)"
  }
}
