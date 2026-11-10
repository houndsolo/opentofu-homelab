mock_provider "vyoscmd" {}
mock_provider "dns" {}
mock_provider "random" {
  mock_resource "random_bytes" {
    defaults = { base64 = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" }
  }
}

variables {
  ssh_private_key_path = "/dev/null"
  dns_tsig_secret      = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
}

run "default_records" {
  command = plan
  assert {
    condition = (
      dns_a_record_set.records["greatfox|A"].addresses == toset(["10.20.7.20"]) &&
      dns_a_record_set.records["leaf-17|A"].addresses == toset(["10.20.10.17"]) &&
      dns_a_record_set.records["fichina|A"].zone == "lylat.space."
    )
    error_message = "Generate management and leaf A records as DNS-provider resources."
  }
  assert {
    condition = (
      output.dns_addresses == { dns01 = "10.8.53.1", dns02 = "10.8.53.2" } &&
      length(terraform_data.bind9) == 2 &&
      !strcontains(local.zone_data, "greatfox")
    )
    error_message = "Bootstrap both VMs, but keep user records out of the seed zone."
  }
}

run "custom_records" {
  command = plan
  variables {
    dns_hosts = {
      greatfox    = { A = "10.20.7.20", AAAA = "fd69:20::20" }
      www         = { CNAME = "greatfox.lylat.space." }
      "@"         = { MX = "10 mail.lylat.space.", TXT = "hello world" }
      sub         = { NS = "dns01.lylat.space." }
      pointer     = { PTR = "greatfox.lylat.space." }
      "_dns._udp" = { SRV = "0 5 53 dns01.lylat.space." }
    }
    dns_records = [
      { name = "app", type = "A", data = "10.8.10.1", ttl = 60 },
      { name = "app", type = "A", data = "10.8.10.2", ttl = 60 },
    ]
  }
  assert {
    condition = (
      dns_aaaa_record_set.records["greatfox|AAAA"].addresses == toset(["fd69:20::20"]) &&
      dns_cname_record.records["www|CNAME"].cname == "greatfox.lylat.space." &&
      dns_txt_record_set.records["@|TXT"].txt == toset(["hello world"]) &&
      dns_txt_record_set.records["@|TXT"].name == null &&
      dns_ns_record_set.records["sub|NS"].nameservers == toset(["dns01.lylat.space."]) &&
      dns_ptr_record.records["pointer|PTR"].ptr == "greatfox.lylat.space." &&
      one(dns_mx_record_set.records["@|MX"].mx).preference == 10 &&
      one(dns_srv_record_set.records["_dns._udp|SRV"].srv).port == 53 &&
      dns_a_record_set.records["app|A"].addresses == toset(["10.8.10.1", "10.8.10.2"]) &&
      dns_a_record_set.records["app|A"].ttl == 60
    )
    error_message = "Map all eight supported types, repeated values and apex names into native resources."
  }
}

run "reject_mixed_rrset_ttls" {
  command = plan
  variables {
    dns_records = [
      { name = "app", type = "A", data = "10.8.10.1", ttl = 60 },
      { name = "app", type = "A", data = "10.8.10.2", ttl = 300 },
    ]
  }
  expect_failures = [var.dns_records]
}

run "reject_bootstrap_override" {
  command = plan
  variables { dns_hosts = { dns01 = { A = "10.8.99.1" } } }
  expect_failures = [var.dns_hosts]
}

run "reject_unsupported_type" {
  command = plan
  variables { dns_hosts = { "@" = { CAA = "0 issue letsencrypt.org" } } }
  expect_failures = [var.dns_hosts]
}

run "reject_dns_vm_without_service_address" {
  command = plan
  variables {
    vms = {
      dns01 = { owner = "services-vms", role = "dns", node = "venom", vm_id = 5301, network_devices = [{ bridge = "vmbr4000" }] }
    }
  }
  expect_failures = [var.vms]
}

run "generate_tsig_by_default" {
  command = plan
  variables { dns_tsig_secret = null }
  assert {
    condition     = length(random_bytes.dns_tsig) == 1 && random_bytes.dns_tsig[0].length == 32
    error_message = "Generate a persistent 32-byte TSIG secret when none is supplied."
  }
}

run "dhcp_pair_identity" {
  command = plan
  assert {
    condition = (
      local.dhcp_ha.dhcp01.role == "primary" &&
      local.dhcp_ha.dhcp01.address_slot == 1 &&
      local.dhcp_ha.dhcp01.peer_name == "dhcp02" &&
      local.dhcp_ha.dhcp01.peer_management_ip == "10.20.67.2" &&
      local.dhcp_ha.dhcp02.role == "secondary" &&
      local.dhcp_ha.dhcp02.address_slot == 2 &&
      local.dhcp_ha.dhcp02.peer_name == "dhcp01"
    )
    error_message = "Order DHCP identities by VM ID and pair local/remote endpoints correctly."
  }
}

run "dhcp_pools_match_example" {
  command = plan
  assert {
    condition = alltrue(flatten([
      for name in ["dhcp01", "dhcp02"] : [
        for command in split("\n", trimspace(file("${path.module}/tests/fixtures/dhcp-pools.set"))) :
        contains(module.dhcp[name].commands, command)
      ]
    ]))
    error_message = "Both DHCP peers must generate every pool/listen command from the supplied example."
  }
  assert {
    condition = alltrue([
      for name in ["dhcp01", "dhcp02"] :
      !contains(module.dhcp[name].commands, "set service dhcp-server listen-interface 'eth0'") &&
      !strcontains(join("\n", module.dhcp[name].commands), "shared-network-name l2vni9011")
    ])
    error_message = "Exclude management and L2VNIs without DHCP enabled."
  }
}

run "preserve_ha_peer_configuration" {
  command = plan
  assert {
    condition = (
      contains(module.dhcp["dhcp01"].commands, "set service dhcp-server high-availability mode 'active-passive'") &&
      contains(module.dhcp["dhcp01"].commands, "set service dhcp-server high-availability source-address '10.21.67.1'") &&
      contains(module.dhcp["dhcp01"].commands, "set service dhcp-server high-availability remote '10.21.67.2'") &&
      contains(module.dhcp["dhcp01"].commands, "set service dhcp-server high-availability status 'primary'") &&
      contains(module.dhcp["dhcp02"].commands, "set service dhcp-server high-availability source-address '10.21.67.2'") &&
      contains(module.dhcp["dhcp02"].commands, "set service dhcp-server high-availability remote '10.21.67.1'") &&
      contains(module.dhcp["dhcp02"].commands, "set service dhcp-server high-availability status 'secondary'") &&
      contains(module.dhcp["dhcp01"].commands, "set service dhcp-server high-availability name 'dhcp02'") &&
      contains(module.dhcp["dhcp02"].commands, "set service dhcp-server high-availability name 'dhcp01'")
    )
    error_message = "Keep the supplied active-passive HA roles, opposite source/remote addresses and real peer names on both peers."
  }
  assert {
    condition = (
      module.dhcp_macs.ha_interfaces.dhcp01 == "eth${length(module.dhcp_macs.data_network_devices.dhcp01) + 1}" &&
      contains(module.dhcp["dhcp01"].commands, "set interfaces ethernet ${module.dhcp_macs.ha_interfaces.dhcp01} hw-id 02:00:00:67:01:ff") &&
      contains(module.dhcp["dhcp01"].commands, "set interfaces ethernet ${module.dhcp_macs.ha_interfaces.dhcp01} address '10.21.67.1/24'") &&
      contains(module.dhcp["dhcp02"].commands, "set interfaces ethernet ${module.dhcp_macs.ha_interfaces.dhcp02} address '10.21.67.2/24'") &&
      !contains(module.dhcp["dhcp01"].commands, "set service dhcp-server listen-interface '${module.dhcp_macs.ha_interfaces.dhcp01}'")
    )
    error_message = "Kea HA runs on the last NIC (ha_dhcp L2VNI, MAC ..:ff, /24 hosts .1/.2), and Kea doesn't listen for clients there."
  }
}

run "dns_vrrp" {
  command = plan
  assert {
    condition = (
      output.dns_vip == "10.8.53.53" &&
      length(terraform_data.dns_keepalived) == 2 &&
      local.dns_nics.dns01 == { service = "eth1", ha = { interface = "eth2", address = "10.21.53.1" } } &&
      strcontains(local.dns_keepalived_scripts.dns01, base64encode(templatefile("${path.module}/templates/dns-keepalived-check.sh.tftpl", { address = "10.8.53.1" })))
    )
    error_message = "keepalived on both DNS VMs: VIP on the service NIC, adverts on the ha_dns NIC, health check on the own address."
  }
}

run "dns_vrrp_disabled" {
  command = plan
  variables { dns_vrrp = null }
  assert {
    condition     = output.dns_vip == null && length(terraform_data.dns_keepalived) == 0 && length(random_password.dns_vrrp) == 0
    error_message = "dns_vrrp = null deploys no keepalived and no VIP."
  }
}

run "dns_journal_to_loki" {
  command = plan
  assert {
    condition = (
      length(terraform_data.dns_syslog) == 2 &&
      strcontains(local.dns_syslog_script, base64encode(templatefile("${path.module}/templates/rsyslog-loki.conf.tftpl", { host = "10.20.11.101", port = 514, level = "info" }))) &&
      strcontains(templatefile("${path.module}/templates/rsyslog-loki.conf.tftpl", { host = "10.20.11.101", port = 514, level = "info" }), "target=\"10.20.11.101\"")
    )
    error_message = "Forward both DNS VMs' journals to the mgmt Loki VIP over TCP by default."
  }
}

run "dns_syslog_disabled" {
  command = plan
  variables { dns_syslog = null }
  assert {
    condition     = length(terraform_data.dns_syslog) == 0 && length(terraform_data.bind9) == 2
    error_message = "dns_syslog = null skips the forwarder but still deploys BIND."
  }
}

run "reject_bad_dns_syslog_level" {
  command = plan
  variables { dns_syslog = { host = "10.20.11.101", level = "verbose" } }
  expect_failures = [var.dns_syslog]
}

run "dns_node_exporter" {
  command = plan
  assert {
    condition = (
      length(terraform_data.dns_node_exporter) == 2 &&
      strcontains(local.dns_node_exporter_script.dns01, base64encode(templatefile("${path.module}/templates/node-exporter.container.tftpl", { image = "docker.io/prom/node-exporter:v1.12.1", listen = "10.20.53.1:9100" }))) &&
      strcontains(local.dns_node_exporter_script.dns02, "http://10.20.53.2:9100/metrics") &&
      # The collectors of monitoring-config's VMs, and the D-Bus socket the systemd one needs.
      strcontains(templatefile("${path.module}/templates/node-exporter.container.tftpl", { image = "i", listen = "10.20.53.1:9100" }), "\nExec=--path.rootfs=/host --web.listen-address=10.20.53.1:9100 --collector.processes --collector.tcpstat --collector.interrupts --collector.systemd --collector.systemd.unit-include=.+[.](service|socket|timer)\n") &&
      strcontains(templatefile("${path.module}/templates/node-exporter.container.tftpl", { image = "i", listen = "10.20.53.1:9100" }), "\nVolume=/run/dbus/system_bus_socket:/var/run/dbus/system_bus_socket:ro\n")
    )
    error_message = "node_exporter on both DNS VMs, listening on their management address :9100, with the processes/tcpstat/interrupts/systemd collectors."
  }
}

run "dns_node_exporter_disabled" {
  command = plan
  variables { dns_node_exporter = null }
  assert {
    condition     = length(terraform_data.dns_node_exporter) == 0
    error_message = "dns_node_exporter = null installs nothing."
  }
}
