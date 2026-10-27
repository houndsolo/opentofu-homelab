# Roots

Each root has independent local state. Shared `.tf` and `.auto.tfvars` symlinks
point into `inventory/`; edit their targets there.

| Order | Root | Purpose / prerequisite |
| --- | --- | --- |
| 1 | proxmox-download-files | Optional Debian image download; skip for an existing customized image |
| 2 | proxmox-network | Proxmox Ethernet, bonds, bridges and VLANs |
| 3 | fabric-vms | VyOS guests; requires existing image/snippets |
| 4 | fabric-spines | RouterOS BGP/EVPN; requires reachable APIs |
| 5 | fabric-leaves | VyOS fabric; enable guest APIs first |
| 6 | services-vms | DNS and DHCP VMs; requires images and host networking |
| 7 | services-config | Podman/BIND, RFC 2136 records and VyOS DHCP HA/pools |
| 8 | workloads | VMs with `owner = "workloads"` |

`proxmox-settings` is incomplete (`influxdb` is undeclared in its module).
`proxmox-virtual-hosts` is empty. The runner excludes both.

```sh
tooling/walk-roots.sh                         # all usable roots
tooling/walk-roots.sh services-vms services-config
# Or run a command directly:
tooling/with-secrets tofu -chdir=roots/services-config plan
```

The runner orders selected roots as shown above; it does not install images,
enable guest APIs, or configure credentials. See [tooling](../tooling/README.md).
