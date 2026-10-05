# Fabric leaf configuration

This root loads shared fabric, node and Proxmox leaf inventory through relative
symlinks. Preserve those links.

For leaves with `role = "proxmox"`, it obtains `fabric_macs` from the same
`modules/fabric/macs` module used by `fabric-vms`. The fabric leaf's key
identifies the Proxmox node by default; set `proxmox_node` when the leaf has a
different inventory name:

```hcl
fabric = {
  # Include the existing settings, overlay_as and spines fields.
  leaves = {
    fichina = {
      role          = "proxmox"
      management_ip = "10.20.10.11"
      router_id     = "10.255.240.11"
      vtep_ipv6     = "fd69:255:240::11"
    }
    renamed_leaf = {
      role          = "proxmox"
      proxmox_node  = "venom"
      management_ip = "10.20.10.17"
      router_id     = "10.255.240.17"
      vtep_ipv6     = "fd69:255:240::17"
    }
  }
}
```

Configure each guest once. Proxmox-role leaves must resolve to an entry in
`nodes.proxmox`; a missing node fails the plan. Other roles default to `generic`
and receive no Proxmox interface bindings.

The shared leaf module manages only the generated `hw-id` commands, for example:

```text
set interfaces ethernet eth1 hw-id 02:07:11:00:11:01
set interfaces ethernet eth2 hw-id 02:07:11:00:11:02
set interfaces ethernet eth3 hw-id 02:07:11:00:11:03
```

Configure `VYOS_API_KEY` or the sensitive `TF_VAR_vyos_api_key` securely. The
provider uses HTTPS to each leaf's `management_ip` and verifies TLS certificates.
The VyOS API must already be enabled and reachable. No BGP, addressing or other
VyOS configuration is managed by this change.

After installing the local VyOS provider and activating the mirror CLI config:

```sh
tofu -chdir=roots/fabric-leaves init
tofu -chdir=roots/fabric-leaves validate
tofu -chdir=roots/fabric-leaves plan
```

`leaf_specifications` exposes each leaf's `fabric_macs` map;
`interface_binding_commands` exposes the corresponding desired commands. Mocked
plan tests cover shared MAC bindings, aliased node names, other roles and missing
node rejection. No live configuration is applied by those tests.
