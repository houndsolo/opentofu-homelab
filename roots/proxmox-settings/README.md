# proxmox-settings

Proxmox VE host settings that aren't networking, storage or VMs, from
[`proxmox-settings.auto.tfvars`](../../inventory/auto.tfvars/proxmox-settings.auto.tfvars)
(schema: [`inventory/schema/proxmox-settings.tf`](../../inventory/schema/proxmox-settings.tf)).

| Setting | Resource | Scope |
|---|---|---|
| Datacenter options (`datacenter.cfg`): keyboard, language, MAC prefix, next VM ID, migration network/type, HA shutdown policy, CRS (HA scheduling, auto-rebalance), bandwidth limits, notifications, ... | `proxmox_cluster_options` | `datacenter.cluster` = the lylat cluster; `datacenter.greatfox` = the standalone host's own datacenter |
| DNS (search domain, up to 3 servers) | `proxmox_virtual_environment_dns` | every host; per-host override in `nodes` |
| Time zone | `proxmox_virtual_environment_time` | every host; per-host override in `nodes` |

- Proxmox keeps DNS and the time zone per node (no cluster-wide DNS), so one value goes to every
  host in `nodes.proxmox` (cluster nodes through the cluster API, greatfox through its provider
  alias) unless `nodes.<host>` overrides it.
- An attribute left out (null) is not managed. The provider can't manage `tag-style`,
  `allowed-tags` or u2f/webauthn; they stay as set by hand (the tag colors and ordering are noted
  in the tfvars header).
- The existing settings were adopted with the import blocks in `imports.tf`; once in state they are
  no-ops. `tests/settings.tftest.hcl` sets `import_existing = false` (mocked providers can't import).

```sh
tooling/walk-roots.sh proxmox-settings
```
