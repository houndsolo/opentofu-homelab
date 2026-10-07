# Inventory

Shared configuration used by the roots.

| Directory | Contents |
| --- | --- |
| auto.tfvars/ | Configuration values |
| schema/ | Variable types, defaults and validation |
| provider-config/ | Provider configuration and credential variables |
| versions/ | Provider requirements |

## Main value files

| File | Purpose |
| --- | --- |
| nodes.auto.tfvars | Proxmox nodes and stable IDs |
| fabric.auto.tfvars | Fabric members, addressing and MTUs |
| pve-leaf.auto.tfvars | Fabric VM settings |
| pve-network.auto.tfvars | Proxmox host networking |
| vnis.auto.tfvars | VRFs, L2/L3 VNIs, gateways and route targets |
| vms.auto.tfvars | General VM definitions |
| network-services.auto.tfvars | DHCP and DNS VM identities |
| network-services-vm.auto.tfvars | Shared minimal DNS/DHCP VM template |

Edit values here. Roots and modules use relative symlinks to the shared files.

A VNI's `roles` select the leaves that receive its VRF and nested L2VNIs.
Route targets are explicit values; changing the overlay AS does not update them.

Keep credentials outside tracked inventory files. Use environment variables
or private variable files.
