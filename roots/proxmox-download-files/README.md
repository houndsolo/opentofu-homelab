# proxmox-download-files

This root downloads the Debian 13 ("trixie") cloud image into Proxmox, so VMs
can be built from it. It's optional: skip it if you already have the image, or
if you use your own customized image.

## What it does

| Setting | Value |
| --- | --- |
| Source | `https://cloud.debian.org/images/cloud/trixie/20261017-2634/debian-13-genericcloud-amd64-20261017-2634.qcow2` (a pinned build) |
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
- The Proxmox API tokens must be in the [secrets file](../../inventory/README.md#secrets).

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

## Adopting a file that's already there

If the image was downloaded by hand, or by another tool, import it so OpenTofu
doesn't try to download it again. Use the node shown in your plan:

```sh
# Import ID format: <node>/<datastore>:<content type>/<file name>
tooling/with-secrets tofu -chdir=roots/proxmox-download-files import \
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
tooling/with-secrets tofu -chdir=roots/services-vms state rm \
  'proxmox_virtual_environment_download_file.debian13[0]'

# 2. Adopt the file in this root.
tooling/with-secrets tofu -chdir=roots/proxmox-download-files import \
  'proxmox_virtual_environment_download_file.debian13[0]' \
  'eldarad/cephfs:import/debian-13-genericcloud-amd64.qcow2'
```

Only one state should ever manage a given file.
