# ansible

Hand-run OS chores on the Proxmox nodes and gf.pbs that the tofu providers can't do. You run Ansible yourself;
nothing in the roots calls it. Network and settings belong in the roots (`proxmox-network`, `proxmox-settings`),
monitoring in `monitoring-config`. Moved here from `~/network_automation/ansible_stuff/proxmox-lylat` (2026-11-16).

| File | What it does |
|---|---|
| `inventory/tfvars.py` | Dynamic inventory: the Proxmox nodes from `inventory/auto.tfvars/nodes.auto.tfvars`, address = `cidrhost(management_prefix, id)` like the roots. Groups `pve` (all), `cluster` (not standalone; id order), `ceph` (= cluster), `standalone` (greatfox). |
| `inventory/static.yml` | Hosts outside the tfvars: `pbs` = gf.pbs (PBS VM 100 on greatfox, 10.20.8.20). |
| `host_vars/` | Per-host variables (macbeth: `smartd_always_alert`). |
| `setup.pve.yml` | Marked block in root's existing `.bashrc` (vi mode, colour `ls`/`ip`/`grep`; rest of the file untouched), the no-subscription popup patch + apt hook, and on the PVE nodes `tasks/smartd.yml` (smartd alerts on sectors 197/198 only when the count grows, except disks in `smartd_always_alert`). |
| `update-packages.yml` | `apt update` + `apt dist-upgrade` (never plain `apt upgrade`), then says whether a reboot is needed for a new kernel. |
| `reboot.yml` | Rolling reboot of `cluster`, one node at a time in id order, Ceph `noout`, waits for quorum and `active+clean` between nodes. |

Run from this folder, in the repo shell (direnv or `nix-shell`, which provides `ansible` and python-hcl2):

```sh
cd ansible
ansible-inventory --graph                          # what the tfvars produce
ansible-playbook setup.pve.yml --check --diff      # preview per host
ansible-playbook setup.pve.yml                     # second run must show changed=0
ansible-playbook update-packages.yml               # --limit fichina for one node
ansible-playbook reboot.yml                        # only if update said REBOOT NEEDED
inventory/tfvars.py --yaml                         # the generated inventory as a static hosts.yml
```

- greatfox is often off: `--limit cluster` skips greatfox and gf.pbs.
- A new node in `nodes.auto.tfvars` shows up here automatically. A non-Proxmox host goes in `inventory/static.yml`.
- Host config files: add or ensure lines with `blockinfile`/`lineinfile` and a marker, never replace a whole file
  (gf.pbs has its own `PS1`).
- `ansible-playbook --list-hosts` prints hosts in no particular order; plays run in group order (`order: inventory`).
- Tests: `python3 -B -m unittest tooling/tests/test_ansible_inventory.py` from the repo root.
