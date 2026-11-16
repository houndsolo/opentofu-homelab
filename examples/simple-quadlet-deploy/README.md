# Simple Quadlet deploy (proposal)

A minimal version of what [monitoring-config](../../roots/monitoring-config/README.md) and
[services-config](../../roots/services-config/README.md) do: OpenTofu renders config files and Quadlet units,
SSHes to a VM and runs one script that installs them. Standalone: **nothing loads this directory** and no live
VM is touched by it. It runs Prometheus, Grafana and node_exporter on one VM.

| File | What |
| --- | --- |
| `quadlets/*.container.tftpl`, `monitoring.network` | One unit file per service, written out as it lands on the VM. Only the image (and one retention value) is a variable |
| `deploy.sh.tftpl` | The whole deploy script: 48 lines, four numbered steps |
| `main.tf` | The file list (path, mode, owning unit, content), the script per VM, one `terraform_data` that runs it |
| `example.tfvars`, `tests/render.tftest.hcl` | Example input; a plan-only test of the rendered script |

## What the live setup does

Same four steps, with more machinery around each:

1. **Units.** `modules/services/monitoring` describes every container as an HCL object (`backend_container_defs`
   in `main.tf`) and pushes it through one generic template (`templates/container.tftpl`) with 13
   fields, most optional. To see a unit you have to read both and merge them in your head. services-config already does it
   the readable way: one `<service>.container.tftpl` per service.
2. **Transport.** Every file is base64-embedded in a generated `deploy.sh` (3.4 MB for graf01: the dashboards).
3. **Install.** The monitoring `deploy.sh.tftpl` (257 lines) compares content, mode and owner per file, looks up
   each image's runtime uid for ownership, keeps per-file restart and reload lists, prunes directories, tracks
   removed Quadlets in a state file, resolves pinned apt versions, has a `check` mode.
   services-config has seven deploy scripts (71-184 lines each) and six small installer scripts that each repeat a
   smaller form of this.
4. **Health.** A two-minute retry loop over a list of curl commands per VM.

None of that is wrong. Each piece was added for a real case. It is just a lot to read.

## What is simpler here, and what it costs

| Live | Here | You lose |
| --- | --- | --- |
| HCL object + generic unit template | A literal unit file per service | Nothing. Shared lines (node_exporter flags) are repeated per file or stay a template variable |
| curl retry loops in the script | `HealthCmd=` + `Notify=healthy` in the unit: `systemctl restart` itself waits for healthy and fails otherwise | The health check must run inside the container (needs `wget`/`curl` in the image: the Prometheus images and Grafana have one). Checks from outside (a VIP, another host) stay in the script |
| uid lookup + chown of data directories | Podman named volumes (`Volume=prometheus-data:/prometheus`): Podman sets the owner | Data moves to `/var/lib/containers/storage/volumes/<name>/_data`. Existing data would have to be moved, so keep bind mounts for services that already have data |
| Per-file `restart = [...]`, `reload = [...]` lists | One `unit` per file. Changed unit file = restart, any other changed file = `systemctl reload-or-restart` | A file shared by two units. A config that always needs a restart works without extra code: its unit has no `ExecReload`, so reload-or-restart restarts it |
| Content + mode + owner comparison | Content only | A mode-only change isn't noticed until the content changes too |
| Prune directories, Quadlet state file | Not handled | Removing a service or a dashboard needs one manual `rm` + `systemctl stop` (or a `removed` list in the script) |
| `deploy.sh check` mode | Not handled | Dry runs on the VM. `tofu plan` still shows that a VM would redeploy, not which files |
| apt version resolution in shell | Not shown | For keepalived an `apt-get install` line is enough. Pins belong in `/etc/apt/preferences.d` (apt's own mechanism), not in shell |
| Seven deploy scripts in services-config | The same one script for every service | Service-specific steps (CephFS mount, BIND zone seeding, DB schema) become `checks` / extra commands passed in |

Kept on purpose: staging + validation before anything is installed (a broken `prometheus.yml` never lands),
restart only what changed, reload instead of restart for config, a failed deploy fails the apply.

## What I would do with the live roots

In this order, each step on its own and reviewable:

1. **Nothing has to change.** The live setup works. This is about readability.
2. **Monitoring units as literal files** (`prometheus.container.tftpl`, ... like services-config). Rendered output
   can stay byte-identical, so no VM redeploys: compare the rendered units before and after to prove it.
3. **`Notify=healthy` + `HealthCmd`** on the units, dropping the matching entries from the health lists.
   Changes every unit, so it restarts each service once: roll it with `-parallelism=1`.
4. **One shared deploy template** for services-config, replacing the seven copies. Biggest reduction in code,
   and the riskiest: do one service first (ticketing or the exporters), then the rest.
5. Leave Patroni, keepalived and the nft guards alone. Most of their length is the HA design, not the tooling.

A different tool would also do steps 3-4: Ansible's `template` + handlers is exactly "install changed files,
restart what changed". It would mean moving the config rendering out of OpenTofu, which is a rewrite, not a
simplification.

## Try it

```
cd examples/simple-quadlet-deploy
tofu init && tofu test                      # renders, contacts nothing
tofu plan -var-file=example.tfvars          # after pointing hosts at a scratch Debian 13 VM with podman
```

Checked so far: `tofu validate`/`test`, shellcheck on the rendered script, Quadlet's own generator
(`quadlet -dryrun`, Podman 5.8) accepts the four units, and the script's install/restart/reload logic was run
against stubbed `podman`/`systemctl`. **Not yet run on a real VM.**
