# Standalone L2VNIs for HA peer traffic: no VRF, no anycast gateway, no DHCP.
# VLAN = VNI - 9000. VIPs stay on the client-facing NICs; only unicast peer traffic
# (keepalived adverts, Kea HA, Loki/Mimir memberlist/gRPC, Grafana/Alertmanager gossip,
# Postgres replication + etcd) uses these.
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
    description = "Grafana keepalived + alerting HA (graf01 .32, graf02 .33; VIP 10.2.11.100 on VLAN 2)"
  }
  ha_logging = {
    vni         = 9214
    vlan_id     = 214
    prefix      = "10.21.12.0/24"
    description = "Loki memberlist/gRPC + keepalived (loki01-03 .34-.36; VIPs 10.x.11.101)"
  }
  ha_monitor = {
    vni         = 9215
    vlan_id     = 215
    prefix      = "10.21.13.0/24"
    description = "Monitoring keepalived + Alertmanager gossip (mon01 .30, mon02 .31; VIPs 10.5.11.102, 10.13.11.102)"
  }
  ha_mimir = {
    vni         = 9216
    vlan_id     = 216
    prefix      = "10.21.14.0/24"
    description = "Mimir memberlist/gRPC + keepalived (mim01-03 .37-.39; VIP 10.13.11.103 on VLAN 13)"
  }
  ha_postgres = {
    vni         = 9217
    vlan_id     = 217
    prefix      = "10.21.15.0/24"
    description = "Patroni: Postgres streaming replication, etcd peers/clients, Patroni REST API, keepalived (pg01-03 .40-.42; VIP 10.13.11.104 on VLAN 13)"
  }
  ha_triage = {
    vni         = 9218
    vlan_id     = 218
    prefix      = "10.21.16.0/24"
    description = "dark-triage keepalived adverts (triage01-02 .43-.44; VIP 10.2.11.105 on VLAN 2)"
  }
  ha_netbox = {
    vni         = 9219
    vlan_id     = 219
    prefix      = "10.21.17.0/24"
    description = "NetBox keepalived adverts (netbox01-02 .45-.46; VIP 10.2.11.106 on VLAN 2)"
  }
  ha_proxy = {
    vni         = 9220
    vlan_id     = 220
    prefix      = "10.21.18.0/24"
    description = "nginx reverse proxy keepalived adverts (proxy01-02 .50-.51; planned VIP 10.2.11.107 on VLAN 2)"
  }
}
