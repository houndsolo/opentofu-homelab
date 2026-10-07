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

mock_provider "dns" {}
mock_provider "random" {
  mock_resource "random_bytes" {
    defaults = { base64 = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" }
  }
}

# Mock-only inputs. No image is downloaded and no credentials are used.
variables {
  pve_api_token        = "mock-only"
  gf_api_token         = "mock-only"
  ssh_private_key_path = "tests/fixtures/id_test"
}

run "four_service_vms" {
  command = plan
  assert {
    condition     = join(",", sort(keys(output.vms))) == "dhcp1,dhcp2,dns1,dns2"
    error_message = "The service inventory must produce exactly the four requested VMs."
  }
  assert {
    condition = alltrue([
      for vm in values(merge(module.dhcp, module.dns)) :
      vm.hardware.cpu_cores == 2 && vm.hardware.memory_mb == 2048 && vm.hardware.disk_size_gb == 10
    ])
    error_message = "All four service VMs must use the 2-core, 2-GiB, 10-GiB shared template."
  }
  assert {
    condition     = output.vms.dhcp1.vm_id == 6701 && output.vms.dhcp2.vm_id == 6702
    error_message = "The updated DHCP VM IDs must be preserved."
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
      length(module.dhcp["dhcp1"].network_devices) == 0 &&
      length(module.dhcp["dhcp2"].network_devices) == 0 &&
      length(module.dhcp["dhcp1"].ip_configs) == 1
    )
    error_message = "DHCP must have only its management NIC while service interfaces are deferred."
  }
  assert {
    condition = (
      join(",", yamldecode(proxmox_virtual_environment_file.dns_user_data["dns1"].source_raw[0].data).packages) == "qemu-guest-agent,net-tools,podman" &&
      yamldecode(proxmox_virtual_environment_file.dns_user_data["dns1"].source_raw[0].data).users[0].ssh_authorized_keys[0] == trimspace(file("${pathexpand(var.ssh_private_key_path)}.pub"))
    )
    error_message = "Debian bootstrap must preserve the guest agent, net-tools, Podman and the matching SSH public key."
  }
}

run "shared_hardware_template" {
  command = plan
  variables {
    network_services_vm = merge(var.network_services_vm, {
      cpu_cores    = 3
      memory_mb    = 3072
      disk_size_gb = 20
    })
  }
  assert {
    condition = alltrue([
      for vm in values(merge(module.dhcp, module.dns)) :
      vm.hardware.cpu_cores == 3 && vm.hardware.memory_mb == 3072 && vm.hardware.disk_size_gb == 20
    ])
    error_message = "One shared template must control the hardware of both DNS and DHCP guests."
  }
}

run "reject_duplicate_service_ids" {
  command = plan
  variables {
    network_services = merge(var.network_services, {
      dns = merge(var.network_services.dns, {
        dns1 = merge(var.network_services.dns.dns1, { vm_id = var.network_services.dhcp.dhcp1.vm_id })
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

run "bind9_plan" {
  command = plan
  assert {
    condition     = join(",", sort(keys(terraform_data.bind9))) == "dns1,dns2"
    error_message = "Only DNS VMs should receive the BIND9 deployment."
  }
  assert {
    condition = alltrue([
      for deployment in values(terraform_data.bind9) :
      strcontains(deployment.triggers_replace[0].named_conf, "forwarders { 1.1.1.1; 1.0.0.1; };") &&
      strcontains(deployment.triggers_replace[0].named_conf, "forward only;") &&
      strcontains(deployment.triggers_replace[0].named_conf, "allow-recursion { clients; };") &&
      strcontains(deployment.triggers_replace[0].zone, "dns1 IN A 10.8.53.1")
    ])
    error_message = "Both resolvers must use Cloudflare upstreams and serve the inventory's local DNS records."
  }
  assert {
    condition = (
      strcontains(terraform_data.bind9["dns1"].triggers_replace[0].quadlet, "PublishPort=10.8.53.1:53:53/tcp") &&
      strcontains(terraform_data.bind9["dns2"].triggers_replace[0].quadlet, "PublishPort=10.8.53.2:53:53/udp") &&
      strcontains(terraform_data.bind9["dns1"].triggers_replace[0].quadlet, "Volume=/etc/bind9:/etc/bind:ro") &&
      strcontains(terraform_data.bind9["dns1"].triggers_replace[0].quadlet, "Volume=/var/lib/bind9:/var/lib/bind:rw") &&
      strcontains(terraform_data.bind9["dns1"].triggers_replace[0].quadlet, "Tmpfs=/var/cache/bind:rw,mode=1777") &&
      strcontains(terraform_data.bind9["dns1"].triggers_replace[0].quadlet, "WantedBy=multi-user.target")
    )
    error_message = "Quadlet must bind the service IPs, protect configuration, provide writable runtime storage and start at boot."
  }
}

run "bind9_inventory_changes" {
  command = plan
  variables {
    network_services = merge(var.network_services, {
      dns = merge(var.network_services.dns, {
        dns2 = merge(var.network_services.dns.dns2, { service_address = "10.8.53.22/16" })
      })
    })
  }
  assert {
    condition = (
      dns_a_record_set.servers["dns2"].addresses == toset(["10.8.53.22"]) &&
      strcontains(terraform_data.bind9["dns1"].triggers_replace[0].named_conf, "also-notify { 10.8.53.22 key") &&
      strcontains(terraform_data.bind9["dns2"].triggers_replace[0].quadlet, "PublishPort=10.8.53.22:53:53/tcp")
    )
    error_message = "Service IP changes must update the provider-managed record, primary notifications and secondary listener."
  }
}

run "provider_managed_records" {
  command = plan
  assert {
    condition = (
      dns_a_record_set.servers["dns1"].zone == "lylat.space." &&
      dns_a_record_set.servers["dns1"].addresses == toset(["10.8.53.1"]) &&
      dns_a_record_set.servers["dns2"].addresses == toset(["10.8.53.2"])
    )
    error_message = "The DNS provider must own both server A records."
  }
  assert {
    condition = (
      strcontains(terraform_data.bind9["dns1"].triggers_replace[0].named_conf, "type primary;") &&
      strcontains(terraform_data.bind9["dns1"].triggers_replace[0].named_conf, "allow-update { key \"opentofu.lylat.space.\"; };") &&
      strcontains(terraform_data.bind9["dns2"].triggers_replace[0].named_conf, "type secondary;") &&
      strcontains(terraform_data.bind9["dns2"].triggers_replace[0].named_conf, "primaries { 10.8.53.1 key \"opentofu.lylat.space.\"; };")
    )
    error_message = "dns1 must accept signed updates, and dns2 must transfer the zone using the shared key."
  }
}
