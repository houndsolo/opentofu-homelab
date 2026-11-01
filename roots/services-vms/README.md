# services-vms

This root creates the **DNS and DHCP VMs**. It only builds the VMs (hardware,
disks, NICs, cloud-init). The software inside them is set up afterwards by
[services-config](../services-config/README.md).

## Which VMs

Every entry in [`vms.auto.tfvars`](../../inventory/auto.tfvars/vms.auto.tfvars)
with `owner = "services-vms"`. Its `role` says what kind of service VM it is:
`dns`, `dhcp`, or no role at all for any other service VM. All of them are built
with the shared [VM module](../../modules/README.md#proxmoxvm). Today that's
(2 cores and 2048 MB each, set in `config`):

| VM | Role | Node | VM ID | Image | Management (eth0) | Data NICs |
| --- | --- | --- | --- | --- | --- | --- |
| `dns01` | `dns` | venom | 5301 | `debian13` | `10.20.53.1/16` | eth1: `vmbr4000` VLAN 8, `10.8.53.1/16`, gateway `10.8.0.5` |
| `dns02` | `dns` | eldarad | 5302 | `debian13` | `10.20.53.2/16` | eth1: `vmbr4000` VLAN 8, `10.8.53.2/16`, gateway `10.8.0.5` |
| `dhcp01` | `dhcp` | venom | 6701 | `vyos` | `10.20.67.1/16` | generated (see below) |
| `dhcp02` | `dhcp` | eldarad | 6702 | `vyos` | `10.20.67.2/16` | generated |

Each pair is split across two hosts, so losing one host doesn't take out DNS or
DHCP.

## DNS VMs

- **NICs.** They get exactly the NICs listed in the inventory: the management
  NIC (net0 on `vmbr0`) plus `network_devices`.
- **Cloud-init** sets both addresses at first boot. It also creates
  `config.ssh_username` with the keys selected in `config.ssh_pubkeys`.
- **Routing.** There's no management gateway, so the data NIC's gateway
  (`10.8.0.5`, the anycast gateway on the local leaf) is the VM's only default
  route.

Before `services-config` can set them up, the DNS VMs also need:

- **Exactly one NIC with an `ipv4_address`.** That address becomes the DNS
  service address, and `plan` fails if there are none or several. Today it's the
  VLAN 8 NIC on `vmbr4000`.
- **Podman** (with Quadlet) and **qemu-guest-agent**. The stock Debian cloud
  image includes neither; see
  [proxmox-download-files](../proxmox-download-files/README.md#this-is-the-stock-image).
- **Internet access** through VLAN 8, to pull the BIND container image.

## DHCP VMs

You never list the DHCP VMs' data NICs yourself. This root generates them from
the VLANs, and replaces any `network_devices` you write:

- **One NIC per DHCP-enabled VLAN.** That's every L2VNI with a `dhcp` block in
  `vnis.auto.tfvars`, sorted by VLAN number.
- **On `vmbr4000`**, tagged with the VLAN.
- **With a fixed MAC**, `02:00:00:67:<VM ID % 100>:<VLAN>`, from
  [modules/services/dhcp/macs](../../modules/services/dhcp/macs/README.md).

With today's VLANs, `dhcp01` gets these (`dhcp02` is the same with `:02:` in
place of `:01:`):

| Interface | VLAN | MAC |
| --- | --- | --- |
| eth1 | 2 | `02:00:00:67:01:02` |
| eth2 | 6 | `02:00:00:67:01:06` |
| eth3 | 8 | `02:00:00:67:01:08` |
| eth4 | 9 | `02:00:00:67:01:09` |
| eth5 | 10 | `02:00:00:67:01:10` |
| eth6 | 12 | `02:00:00:67:01:12` |

VLAN 11 has no `dhcp` block, so it gets no NIC.

Cloud-init only configures the management NIC on the DHCP VMs. Their VLAN
addresses (`10.<VLAN>.67.<1|2>`) are set later by `services-config` through
the VyOS API.

Rules that are checked for you:

- Exactly two DHCP VMs, or none.
- Unique VM IDs between 6701 and 6799.
- DHCP VLANs between 1 and 99.

**Adding or removing a DHCP VLAN renumbers the NICs.** Every VLAN keeps its MAC,
but every VLAN numbered above the one you added or removed moves to a different
`ethN`. Plan `services-vms` and `services-config` together, and apply them one
after the other.

## Good to know

- **VLAN tagging is done by Proxmox.** The guest sees ordinary, untagged NICs.
  The bridge just has to carry the VLAN (`vmbr4000` is VLAN-aware on every
  node).
- **SSH keys are selected by name** from
  [`ssh_pubkeys.tf`](../../inventory/ssh_pubkeys.tf). An unknown name fails the
  plan. Keys can't be combined with a custom cloud-init user-data snippet.
- **Cloud-init runs at first boot only.** If you change the addresses or keys of
  an existing VM, you'll need to change them in the guest by hand, or recreate
  the VM.

## Running it

```sh
tooling/walk-roots.sh services-vms services-config
```

The `vms` output lists each VM's ID, node, name and management address.
