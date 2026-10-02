# Host-side networking intent for the hypervisor fleet, organized as reusable
# profiles. Which profile a host uses is assigned per host in nodes.auto.tfvars
# (nodes.proxmox.<name>.network_profile); per-host addresses are derived from
# node IDs against the bridge/VLAN prefixes below.
pve_network = {
  eths = {
    0 = {
      mtu         = 9119
      description = "mgmt"
    }
    1 = {
      mtu         = 9119
      description = "vxlan l2 out"
    }
    7 = {
      mtu         = 9119
      description = "proxmox cluster network"
    }
    10 = {
      mtu         = 9119
      description = "lan"
    }
    22 = {
      mtu         = 9600
      description = "ceph private"
    }
    27 = {
      mtu         = 9600
      description = "ceph public"
    }
    4001 = {
      mtu         = 9189
      description = "link to spine1"
    }
    4002 = {
      mtu         = 9189
      description = "link to spine2"
    }
  }

  bonds = {
    0 = {
      mtu                   = 9600
      description           = "ceph"
      bond_mode             = "802.3ad"
      bond_xmit_hash_policy = "layer3+4"
      slaves = [
        "eth22",
        "eth27"
      ]
    }
  }

  vlans = {
    2 = {
      mtu         = 1500
      description = "vxlan-webui"
      port        = "vmbr4000"
      ipv4 = {
        cidrhost_prefix = "10.2.0.0/24"
        cidr            = 16
      }
    }
    22 = {
      mtu         = 9600
      description = "ceph-private"
      port        = "bond0"
    }
    27 = {
      mtu         = 9600
      description = "ceph-public"
      port        = "bond0"
    }
  }

  bridges = {
    0 = {
      mtu         = 9119
      description = "mgmt"
      vlan_aware  = false
      ports = [
        "eth0"
      ]
      ipv4 = {
        cidrhost_prefix = "10.20.7.0/24"
        cidr            = 16
      }
    }
    1 = {
      mtu         = 9119
      description = "lan"
      vlan_aware  = true
      ipv4 = {
        cidrhost_prefix = "10.7.1.0/24"
        cidr            = 24
      }
      ports = [
        "eth10"
      ]
    }
    7 = {
      mtu         = 9000
      description = "cluster management"
      vlan_aware  = false
      ports = [
        "eth7"
      ]
      ipv4 = {
        cidrhost_prefix = "10.7.0.0/24"
        cidr            = 24
      }
    }
    22 = {
      mtu         = 9600
      description = "ceph private"
      vlan_aware  = false
      ports = [
        "bond0.22"
      ]
      ipv4 = {
        cidrhost_prefix = "10.22.0.0/24"
        cidr            = 16
      }
    }
    27 = {
      mtu         = 9600
      description = "ceph public"
      vlan_aware  = false
      ports = [
        "bond0.27"
      ]
      ipv4 = {
        cidrhost_prefix = "10.27.0.0/24"
        cidr            = 16
      }
    }
    100 = {
      mtu         = 9119
      description = "vxlan l2 out"
      vlan_aware  = true
      gateway     = "10.5.0.255"
      ipv4 = {
        cidrhost_prefix = "10.5.1.0/24"
        cidr            = 16
      }
      ports = [
        "eth1"
      ]
    }
    4000 = {
      mtu         = 9119
      description = "vxlan fabric access"
      vlan_aware  = true
    }
    4001 = {
      mtu         = 9189
      description = "vxlan leaf to spine 1"
      vlan_aware  = true
      ports = [
        "eth4001"
      ]
    }
    4002 = {
      mtu         = 9189
      description = "vxlan leaf to spine 2"
      vlan_aware  = true
      ports = [
        "eth4002"
      ]
    }
    4010 = {
      mtu         = 9119
      description = "TEST vxlan fabric access"
      vlan_aware  = true
    }
    4011 = {
      mtu         = 9189
      description = "TEST vxlan leaf to spine 1"
      vlan_aware  = true
    }
    4012 = {
      mtu         = 9189
      description = "TEST vxlan leaf to spine 2"
      vlan_aware  = true
    }
  }
}

