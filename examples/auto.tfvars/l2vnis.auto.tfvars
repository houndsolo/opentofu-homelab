# Standalone L2VNIs for HA peer traffic: no VRF, no anycast gateway, no DHCP.
# The leaves get the VLAN<->VNI mapping, the access trunk VLAN and an address-less SVI.
# services-config peers the DHCP pair over ha_dhcp (hosts .1 and .2 of prefix).
l2vnis = {
  ha_dhcp = {
    vni         = 9211
    vlan_id     = 211 # VLAN = VNI - 9000
    prefix      = "10.21.67.0/24"
    description = "DHCP Kea HA heartbeat"
  }
}
