# Standalone L2VNIs for HA peer traffic: no VRF, no anycast gateway, no DHCP. Zone design (Obsidian
# homelab-docs/evpn-fabric/zone-design.md, DT-090): app id aa, VLAN 10aa / VNI 50aa / 10.50.aa.0/24
# (IPv6 fd69:50aa::/64 on the VMs), host octet = the VM's host octet. VIPs stay on the client-facing NICs; only
# unicast peer traffic (keepalived adverts, Kea HA, Loki/Mimir memberlist/gRPC, Grafana/Alertmanager gossip,
# Postgres replication + etcd) uses these. The old VLAN 211-220 / VNI 9211-9220 / 10.21.x segments were removed
# on 2026-11-14 after every VM had moved.
l2vnis = {
  ha_dhcp = {
    vni         = 5009
    vlan_id     = 1009
    prefix      = "10.50.9.0/24"
    description = "DHCP Kea HA heartbeat (dhcp01 .1, dhcp02 .2)"
  }
  ha_proxy = {
    vni         = 5010
    vlan_id     = 1010
    prefix      = "10.50.10.0/24"
    description = "nginx reverse proxy keepalived adverts (proxy01-02 .50-.51; VIP 10.2.11.107 on VLAN 2)"
  }
  ha_grafana = {
    vni         = 5011
    vlan_id     = 1011
    prefix      = "10.50.11.0/24"
    description = "Grafana keepalived + alerting HA (graf01 .32, graf02 .33; VIP 10.2.11.100 on VLAN 2)"
  }
  ha_netbox = {
    vni         = 5012
    vlan_id     = 1012
    prefix      = "10.50.12.0/24"
    description = "NetBox keepalived adverts (netbox01-02 .45-.46; VIP 10.2.11.106 on VLAN 2)"
  }
  ha_triage = {
    vni         = 5013
    vlan_id     = 1013
    prefix      = "10.50.13.0/24"
    description = "dark-triage keepalived adverts (triage01-02 .43-.44; VIP 10.2.11.105 on VLAN 2)"
  }
  ha_postgres = {
    vni         = 5014
    vlan_id     = 1014
    prefix      = "10.50.14.0/24"
    description = "Patroni: Postgres streaming replication, etcd peers/clients, Patroni REST API, keepalived (pg01-03 .40-.42)"
  }
  ha_monitor = {
    vni         = 5016
    vlan_id     = 1016
    prefix      = "10.50.16.0/24"
    description = "Monitoring keepalived + Alertmanager gossip (mon01 .30, mon02 .31)"
  }
  ha_mimir = {
    vni         = 5017
    vlan_id     = 1017
    prefix      = "10.50.17.0/24"
    description = "Mimir memberlist/gRPC + keepalived (mim01-03 .37-.39)"
  }
  ha_logging = {
    vni         = 5018
    vlan_id     = 1018
    prefix      = "10.50.18.0/24"
    description = "Loki memberlist/gRPC + keepalived (loki01-03 .34-.36)"
  }
  ha_dns = {
    vni         = 5053
    vlan_id     = 1053
    prefix      = "10.50.53.0/24"
    description = "DNS keepalived (dns01 .51, dns02 .52; VIP 10.8.53.53 on VLAN 8)"
  }
}
