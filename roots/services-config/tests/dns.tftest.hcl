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
      contains(module.dhcp["dhcp01"].commands, "set service dhcp-server high-availability source-address '10.6.67.1'") &&
      contains(module.dhcp["dhcp01"].commands, "set service dhcp-server high-availability remote '10.6.67.2'") &&
      contains(module.dhcp["dhcp01"].commands, "set service dhcp-server high-availability status 'primary'") &&
      contains(module.dhcp["dhcp02"].commands, "set service dhcp-server high-availability source-address '10.6.67.2'") &&
      contains(module.dhcp["dhcp02"].commands, "set service dhcp-server high-availability remote '10.6.67.1'") &&
      contains(module.dhcp["dhcp02"].commands, "set service dhcp-server high-availability status 'secondary'")
    )
    error_message = "Keep the supplied active-passive HA roles and opposite source/remote addresses on both peers."
  }
}
