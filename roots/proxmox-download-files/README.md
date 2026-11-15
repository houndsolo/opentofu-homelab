# proxmox-download-files

Manages the Debian 13 cloud image every `debian13` VM imports from.

| Setting | Value |
| --- | --- |
| Source | `https://cloud.debian.org/images/cloud/trixie/20261017-2634/debian-13-genericcloud-amd64-20261017-2634.qcow2` (pinned build; the file on cephfs is a customized copy, see below) |
| Saved as | `cephfs:import/debian-13-genericcloud-amd64.qcow2` (= `vm_images.debian13.import_image` in [`vm-config.auto.tfvars`](../../inventory/auto.tfvars/vm-config.auto.tfvars)) |
| Content type | `import` (cephfs must allow it: Datacenter → Storage → cephfs → Content) |
| `overwrite` | `false` |
| Node | first (sorted) node hosting a `debian13` VM; cephfs is shared, so one download serves all. No such VM = nothing created. |

```sh
tooling/walk-roots.sh proxmox-download-files
```

## The file on cephfs is customized: never let a plan replace it

The live file is the 20261017-2634 build customized in place on 2026-10-19 (1259536384 bytes,
sha512 `b96e0d83…`); the untouched download (sha512 `ec584cca…`, the published checksum) is kept
beside it as `debian-13-genericcloud-amd64.qcow2.bak`. No upstream URL or checksum matches it, so:

- it was adopted by import (2026-11-14), the resource sets no `checksum`, and it ignores `url` and
  `node_name` (both force replacement in the provider: `url` is empty in imported state, the node
  changes when VMs move);
- this root must plan "No changes". A plan that wants to create the file means the state lost it:
  re-import (below), never apply the create;
- moving to a newer build: delete the file (or `state rm` it), change `url`, apply.

## This is the stock image

A fresh download has neither Podman (Quadlet; BIND and the other services run in it) nor
qemu-guest-agent (the VM module enables the agent), which the DNS VMs need before
[services-config](../services-config/README.md#requirements) can deploy. Customize the image
(`virt-customize`) or install them after boot.

## Adopting a file that's already there

```sh
# Import ID: <node>/<datastore>:<content type>/<file name>; use the node from the plan.
tofu -chdir=roots/proxmox-download-files import \
  'proxmox_virtual_environment_download_file.debian13[0]' \
  'eldarad/cephfs:import/debian-13-genericcloud-amd64.qcow2'
```

## Moving the image from an older services-vms state

The download used to live in services-vms (its state no longer has it). The worked example of
moving a file between states: `tofu -chdir=roots/<old root> state rm '<address>'` (state only, the
file stays), then the import above in this root. Only one state may manage a file.
