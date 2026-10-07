# Download images

Wraps `proxmox_download_file` for pinned qcow2 import images. Each `images` entry
has `node`, `datastore_id`, `url`, `file_name` and published SHA512 `checksum`.
Outputs `file_ids` by image key for the VM module's `vm_config.import_image`.

TLS and SHA512 verification are enabled. Existing unmanaged files are not
replaced. The target datastore must permit `import` content; the Proxmox node
must reach the URL. An image on shared storage can be reused across nodes that
access that storage. Create separate entries for node-local storage.

The calling root owns these downloaded files in its state. Avoid overlapping
ownership by other roots. Tests use a mocked provider and create no files.
