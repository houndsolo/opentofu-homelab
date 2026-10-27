# Image downloads

Downloads the pinned Debian 13 cloud image to
`cephfs:import/debian-13-genericcloud-amd64.qcow2`. One Debian VM host downloads
to shared storage; no Debian hosts means no download resource. cephfs must allow
Import content. `overwrite = false` prevents automatic image refresh.

```sh
tooling/walk-roots.sh proxmox-download-files
```

Skip this root if using an existing customized image, or import it first
(substitute the node shown in your plan):

```sh
tooling/with-secrets tofu -chdir=roots/proxmox-download-files import \
  'proxmox_virtual_environment_download_file.debian13[0]' \
  'eldarad/cephfs:import/debian-13-genericcloud-amd64.qcow2'
```

If an older root already owns the download, transfer its state ownership first;
only one state should manage the file. Downloads do not customize the image.
