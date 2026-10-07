mock_provider "proxmox" {}

# Fixture values only: the provider is mocked and no download occurs.
variables {
  images = {
    debian_13 = {
      node         = "fichina"
      datastore_id = "cephfs"
      url          = "https://images.example.test/debian-13-20260101.qcow2"
      file_name    = "debian-test.qcow2"
      checksum     = "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
    }
  }
}

run "verified_import_download" {
  command = plan
  assert {
    condition = (
      proxmox_download_file.this["debian_13"].checksum == var.images.debian_13.checksum &&
      proxmox_download_file.this["debian_13"].checksum_algorithm == "sha512" &&
      proxmox_download_file.this["debian_13"].content_type == "import" &&
      proxmox_download_file.this["debian_13"].verify &&
      !proxmox_download_file.this["debian_13"].overwrite &&
      !proxmox_download_file.this["debian_13"].overwrite_unmanaged
    )
    error_message = "Image downloads must verify SHA512/TLS and avoid unmanaged replacement."
  }
}

run "reject_invalid_checksum" {
  command = plan
  variables {
    images = {
      debian_13 = {
        node         = "fichina"
        datastore_id = "cephfs"
        url          = "https://images.example.test/debian-13-20260101.qcow2"
        file_name    = "debian-test.qcow2"
        checksum     = "not-a-checksum"
      }
    }
  }
  expect_failures = [var.images]
}
