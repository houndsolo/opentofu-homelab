mock_provider "proxmox" {
  mock_resource "proxmox_virtual_environment_file" {
    defaults = { id = "cephfs:snippets/mock-user-data.yaml" }
  }
  mock_resource "proxmox_download_file" {
    defaults = { id = "cephfs:import/debian-test.qcow2" }
  }
}
mock_provider "proxmox" {
  alias = "greatfox"
}

# Mock-only inputs. No image is downloaded and no credentials are used.
variables {
  pve_api_token       = "mock-only"
  gf_api_token        = "mock-only"
  dns_ssh_public_keys = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMockOnlyPublicKeyForPlanTests"]
  debian_image = {
    url       = "https://images.example.test/debian-13-20260101.qcow2"
    file_name = "debian-test.qcow2"
    checksum  = "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
  }
}

run "four_service_vms" {
  command = plan
  assert {
    condition     = join(",", sort(keys(output.vms))) == "dhcp1,dhcp2,dns1,dns2"
    error_message = "The service inventory must produce exactly the four requested VMs."
  }
  assert {
    condition     = output.vms.dhcp1.node == "titania" && output.vms.dhcp2.node == "zoness" && output.vms.dns1.node == "fichina" && output.vms.dns2.node == "fortuna"
    error_message = "Pair members must use the configured distinct hypervisors."
  }
  assert {
    condition     = module.dhcp["dhcp1"].import_image == var.pve_leaf.vm_config.import_image && module.dhcp["dhcp2"].import_image == var.pve_leaf.vm_config.import_image
    error_message = "DHCP must use exactly the VTEP VyOS image."
  }
  assert {
    condition     = module.dns["dns1"].import_image == module.images.file_ids.debian_13 && module.dns["dns2"].import_image == module.images.file_ids.debian_13
    error_message = "Both DNS disks must depend on the downloaded Debian image."
  }
  assert {
    condition = (
      length(module.dns["dns1"].ip_configs) == 2 &&
      module.dns["dns1"].ip_configs[0].address == "10.20.53.1/16" &&
      module.dns["dns1"].ip_configs[0].gateway == null &&
      module.dns["dns1"].ip_configs[1].address == "10.8.53.1/16" &&
      module.dns["dns1"].ip_configs[1].gateway == "10.8.0.5"
    )
    error_message = "DNS cloud-init must match management/service NIC order and use one default route."
  }
  assert {
    condition = (
      output.dhcp_interfaces.dhcp1["9008"].vlan_id == 8 &&
      output.dhcp_interfaces.dhcp1["9008"].mac_address == "02:70:00:01:00:08" &&
      output.dhcp_interfaces.dhcp2["9008"].mac_address == "02:70:00:02:00:08" &&
      length(module.dhcp["dhcp1"].ip_configs) == 1
    )
    error_message = "DHCP service NICs must have distinct stable MACs and no service IP configuration yet."
  }
  assert {
    condition = (
      join(",", yamldecode(proxmox_virtual_environment_file.dns_user_data["dns1"].source_raw[0].data).packages) == "qemu-guest-agent" &&
      yamldecode(proxmox_virtual_environment_file.dns_user_data["dns1"].source_raw[0].data).users[0].ssh_authorized_keys[0] == var.dns_ssh_public_keys[0]
    )
    error_message = "Debian bootstrap must install only the guest agent and include the supplied SSH key."
  }
}

run "reject_empty_ssh_keys" {
  command = plan
  variables { dns_ssh_public_keys = [] }
  expect_failures = [var.dns_ssh_public_keys]
}

run "reject_duplicate_service_ids" {
  command = plan
  variables {
    network_services = merge(var.network_services, {
      dns = merge(var.network_services.dns, {
        dns1 = merge(var.network_services.dns.dns1, { vm_id = 771 })
      })
    })
  }
  expect_failures = [var.network_services]
}

run "reject_unpinned_image" {
  command = plan
  variables {
    debian_image = {
      url       = "https://images.example.test/latest/debian.qcow2"
      file_name = "debian-test.qcow2"
      checksum  = "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
    }
  }
  expect_failures = [var.debian_image]
}
