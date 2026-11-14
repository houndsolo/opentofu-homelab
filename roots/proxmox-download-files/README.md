# proxmox-download-files

This root downloads the Debian 13 ("trixie") cloud image into Proxmox, so VMs
can be built from it. It's optional: skip it if you already have the image, or
if you use your own customized image.

## What it does

| Setting | Value |
| --- | --- |
| Source | `https://cloud.debian.org/images/cloud/trixie/20261017-2634/debian-13-genericcloud-amd64-20261017-2634.qcow2` (a pinned build; see below for the file actually on cephfs) |
| Saved as | `cephfs:import/debian-13-genericcloud-amd64.qcow2` |
| Proxmox content type | `import`: disk images that VMs can import from |
| `overwrite` | `false`: an existing file is never replaced automatically |

That saved path is the one `vm_images.debian13.import_image` points at, in
[`vm-config.auto.tfvars`](../../inventory/auto.tfvars/vm-config.auto.tfvars).

**Which node does the download?** `cephfs` is shared storage, so the image only
needs to be downloaded once, through any single node. The root looks through
`vms` for VMs with `image = "debian13"`, collects their nodes, sorts the names
and uses the first one. With today's inventory that is `eldarad`. If no VM uses
`debian13`, the root creates nothing.

## Before you run it

- The `cephfs` storage must allow the **Import** content type. In the web UI:
  *Datacenter → Storage → cephfs → Content*.
- The chosen node must be able to reach `cloud.debian.org`.
- `proxmox.secret.auto.tfvars` (the Proxmox API tokens) must be linked into this
  root; see [Secrets](../../inventory/README.md#secrets).

```sh
tooling/walk-roots.sh proxmox-download-files
```

## This is the stock image

The download is the plain Debian cloud image, with nothing extra installed. The
DNS VMs need two packages that it doesn't include before
[services-config](../services-config/README.md#requirements) can set them up:

- **Podman** with Quadlet support, which runs BIND as a systemd service
- **qemu-guest-agent**, because the VM module enables the guest agent by default

Either customize the image first (for example with `virt-customize`), upload it,
point `vm_images` at it and skip this root, or install those packages on the VMs
after they boot.

## The file on cephfs today

The live `cephfs:import/debian-13-genericcloud-amd64.qcow2` is **not** the stock
download: it is the 20261017-2634 build customized in place on 2026-10-19
(1259536384 bytes, sha512 `b96e0d83…`). The untouched download (sha512
`ec584cca…`, the published checksum of 20261017-2634) is kept beside it as
`debian-13-genericcloud-amd64.qcow2.bak`. Because no upstream URL or checksum
matches the customized file, it was adopted by import (2026-11-14), the resource
sets no `checksum`, and it ignores `url` and `node_name`. Both force replacement in the
provider: `url` is empty in imported state, and `node_name` is just the first node
with a Debian VM, which changes when VMs move. A plan therefore never offers to
delete and re-download the image VMs import from. To really move to a newer
build, delete the file (or `state rm` it), change `url`, and apply.

## Adopting a file that's already there

If the image was downloaded by hand, or by another tool, import it so OpenTofu
doesn't try to download it again. Use the node shown in your plan:

```sh
# Import ID format: <node>/<datastore>:<content type>/<file name>
tofu -chdir=roots/proxmox-download-files import \
  'proxmox_virtual_environment_download_file.debian13[0]' \
  'eldarad/cephfs:import/debian-13-genericcloud-amd64.qcow2'
```

## Moving the image from an older services-vms state

Earlier versions of this repo downloaded the image from the `services-vms` root.
If you applied `services-vms` back then, its state still contains the download.
Because that code has been removed, the next `services-vms` plan would offer to
**delete** the image. Move the file to this root before you apply `services-vms`:

```sh
# 1. Make services-vms forget the file. This only edits state; the file stays on cephfs.
tofu -chdir=roots/services-vms state rm \
  'proxmox_virtual_environment_download_file.debian13[0]'

# 2. Adopt the file in this root.
tofu -chdir=roots/proxmox-download-files import \
  'proxmox_virtual_environment_download_file.debian13[0]' \
  'eldarad/cephfs:import/debian-13-genericcloud-amd64.qcow2'
```

Only one state should ever manage a given file.
