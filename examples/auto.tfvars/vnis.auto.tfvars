# A list of L3VNIs (VRFs), each containing a map of L2VNIs (VLANs).
# Merge into your inventory: replacing the entire list removes other VNIs.
vnis = [{
  roles           = ["proxmox"] # Leaf roles that receive this VRF.
  vrf             = "services"
  vrf_table       = 100
  vni             = 10000           # L3VNI; must differ from every L2VNI.
  vlan_id         = 100             # L3 bridge VLAN; must also be unique.
  evpn_rt_imports = ["65000:10000"] # Match your fabric's route-target policy.
  evpn_rt_exports = ["65000:10000"]
  l2 = {
    # Current services-config HA peers use 10.6.67.1 and 10.6.67.2.
    # dhcp = {} creates NICs/listen interfaces but no address pool.
    ha = {
      vni             = 9006
      vlan_id         = 6
      anycast_gw_ip   = "10.6.0.1"
      anycast_gw_cidr = 16
      anycast_mac     = "02:00:00:00:06:01"
      dhcp            = {}
    }
    services = {
      vni             = 9008
      vlan_id         = 8
      anycast_gw_ip   = "10.8.0.1" # Advertised as the DHCP default gateway.
      anycast_gw_cidr = 16         # Numeric prefix length, not a CIDR string.
      anycast_mac     = "02:00:00:00:08:01"
      dhcp = {
        scope = {
          # Pools exclude static DNS (.53.x), DHCP (.67.x), and gateway addresses.
          ranges = {
            clients = { start = "10.8.100.10", stop = "10.8.100.200" }
          }
          name_servers  = ["10.8.53.1", "10.8.53.2"]
          domain_name   = "lylat.space"
          domain_search = ["lylat.space"]
          lease_seconds = 86400
          authoritative = true
        }
      }
    }
    # No dhcp block: no DHCP VM NIC or pool for this VLAN.
    storage = {
      vni             = 9012
      vlan_id         = 12
      anycast_gw_ip   = "10.12.0.1"
      anycast_gw_cidr = 16
      anycast_mac     = "02:00:00:00:12:01"
    }
  }
}]
