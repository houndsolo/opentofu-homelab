# Service VMs

This root makes PVE download the official Debian 13 (Trixie) genericcloud
AMD64 QCOW2 before creating service VMs, including dns01 and dns02:

https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2

The cloud image includes cloud-init. It is an imported disk image, rather than
an installer ISO. The download runs once through a Debian VM's node and is
stored on shared `cephfs` as
`cephfs:import/debian-13-genericcloud-amd64.qcow2`.
Enable the `Import` content type on that storage. The PVE API token needs
`Datastore.AllocateTemplate`, `Sys.Audit`, and `Sys.Modify` for the download API.

`overwrite = false` keeps the downloaded image on subsequent applies, even
when Debian updates the `latest` URL. A missing managed file is downloaded again.
If the image already exists before the first apply, import it into state
instead of downloading it again (use the download node shown in the plan):

```sh
tofu -chdir=roots/services-vms import \
  'proxmox_virtual_environment_download_file.debian13[0]' \
  'eldarad/cephfs:import/debian-13-genericcloud-amd64.qcow2'
```

Review the plan before applying. VyOS images and cloud-init snippets still
need to be present separately.
