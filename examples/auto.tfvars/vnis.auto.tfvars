# A list of L3VNIs (VRFs), each containing a map of L2VNIs (VLANs).
# Merge into your inventory: replacing the entire list removes other VNIs.
vnis = [{
  roles     = ["proxmox"] # Leaf roles that receive this VRF.
  vrf       = "services"
  vrf_table = 100
  vni       = 10000 # L3VNI; must differ from every L2VNI.
  vlan_id   = 100   # L3 bridge VLAN; must also be unique.
  # Import both our own VRF and the remote LAN VRF; export only our own RT.
  ipv4_rt_imports = "65000:10000" # Local IPv4 VPN table; separate from EVPN imports.
  ipv4_rt_exports = "65000:10000"
  evpn_rt_imports = ["65000:10000", "65000:20000"]
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
  }, {
  # Downstream VNI example: a different VRF on external_l2-role leaves.
  # Add/select a leaf with that role in fabric.auto.tfvars to instantiate it.
  # Services -> LAN uses destination L3VNI 20000; return traffic uses 10000.
  roles           = ["external_l2"]
  vrf             = "lan"
  vrf_table       = 200
  vni             = 20000
  vlan_id         = 200
  ipv4_rt_imports = "65000:20000"
  ipv4_rt_exports = "65000:20000"
  evpn_rt_imports = ["65000:20000", "65000:10000"] # Reciprocal import for the return path.
  evpn_rt_exports = ["65000:20000"]
  l2 = {
    clients = {
      vni             = 9030
      vlan_id         = 30
      anycast_gw_ip   = "10.30.0.1"
      anycast_gw_cidr = 16
      anycast_mac     = "02:00:00:00:30:01"
      # No DHCP here; a statically addressed host can test cross-VRF routing.
    }
  }
}]
