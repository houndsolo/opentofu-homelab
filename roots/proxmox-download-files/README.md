# Proxmox download files

Separate root for PVE image downloads, independent of service VM creation.
The enabled Debian 13 download uses the previously pinned Trixie build and
stores it at `cephfs:import/debian-13-genericcloud-amd64.qcow2`. A single node
from the Debian VM inventory performs the download to shared cephfs storage.
No resource is created when there are no Debian VM nodes.

```sh
tofu -chdir=roots/proxmox-download-files init
tofu -chdir=roots/proxmox-download-files plan
```

Review and apply this root separately when needed. cephfs must permit `Import`
content. `overwrite = false` prevents automatic refresh of the downloaded image.
If the image already exists, import it rather than overwriting the customized
QCOW2 (substitute the download node shown in the plan):

```sh
tofu -chdir=roots/proxmox-download-files import \
  'proxmox_virtual_environment_download_file.debian13[0]' \
  'eldarad/cephfs:import/debian-13-genericcloud-amd64.qcow2'
```

This root has separate state. If the download resource is still tracked in an
older services-vms state, transfer its state ownership before applying either
root; do not let both states manage the same file. No state migration or
infrastructure apply is performed by adding this configuration.
