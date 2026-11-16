# services/quadlet-deploy

Renders one deploy script for one VM from a list of files. No providers; changes nothing itself: the calling
root uploads the script and runs it as root (`terraform_data` + `remote-exec`).

The script, in order:

1. Runs `setup` commands and installs missing `packages`.
2. Unpacks every file into a private staging directory.
3. Pulls `images` and runs `checks` against the staging directory (`$stage` mirrors `/`). A failure stops here,
   before anything is installed.
4. Creates `dirs`, installs the files whose content differs, sets mode and owner (`once = true`: only when the
   file doesn't exist yet).
5. Deletes files in `prune_dirs` it doesn't install, and stops and removes unit files it installed last time
   but no longer does (list in `/var/lib/tofu-deploy/<name>.units`).
6. `systemctl daemon-reload`, `post_install` commands, then per unit in order: **restart** if one of its unit
   files changed (or a file with `restart = true`) or it isn't running; **reload-or-restart** if another of its
   files changed.
7. Runs `verify` commands (`retry <command>` waits up to two minutes).

Health is the unit's job: a container unit with `HealthCmd=` and `Notify=healthy` makes `systemctl restart`
return only once the container is healthy, so a failed start fails the deploy (the unit's journal is printed).

```hcl
module "deploy" {
  source   = "../../modules/services/quadlet-deploy"
  for_each = local.vms

  name   = "grafana"
  host   = each.key
  images = [local.image]
  files = [
    { path = "/etc/containers/systemd/grafana.container", content = local.unit[each.key], units = ["grafana"] },
    { path = "/etc/grafana/grafana.env", content = local.env, mode = "0600", units = ["grafana"], restart = true },
  ]
  units = ["grafana"]
}
# module.deploy[each.key].script is the script (sensitive).
```

Inputs: `variables.tf`. Tests: `tofu init && tofu test` in this directory.
