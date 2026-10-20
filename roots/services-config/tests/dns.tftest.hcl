mock_provider "random" {
  mock_resource "random_bytes" {
    defaults = {
      base64 = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
    }
  }
}

variables {
  ssh_private_key_path = "/dev/null"
  dns_tsig_secret      = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
}

run "dns_rollout_plan" {
  command = plan

  assert {
    condition = strcontains(templatefile("${path.module}/templates/bind9.container.tftpl", {
      image = var.bind9_image
    }), "Exec=-g -c /etc/bind/named.conf")
    error_message = "Quadlet must pass arguments to the image entrypoint without duplicating named."
  }

  assert {
    condition     = output.dns_addresses == { dns01 = "10.8.53.1", dns02 = "10.8.53.2" }
    error_message = "Only the DNS VMs should be selected, using their service addresses rather than OOB."
  }

  assert {
    condition     = length(terraform_data.bind9) == 2 && terraform_data.bind9["dns01"].triggers_replace[1] == "10.20.53.1/16"
    error_message = "Deploy independently to both DNS VMs over their management network."
  }

  assert {
    condition = (
      strcontains(local.zone_data, "dns01 IN A 10.8.53.1") &&
      strcontains(local.zone_data, "dns02 IN A 10.8.53.2") &&
      strcontains(local.zone_data, "@ IN NS dns02.lylat.space.")
    )
    error_message = "Both servers must serve the same local zone containing both DNS hosts."
  }
}

run "custom_records_plan" {
  command = plan
  variables {
    dns_hosts = {
      greatfox = { A = "10.20.7.20", AAAA = "fd69:20::20" }
      www      = { CNAME = "greatfox.lylat.space." }
      "@"      = { MX = "10 mail.lylat.space.", CAA = "0 issue \"letsencrypt.org\"" }
    }
    dns_records = [
      { name = "app", type = "A", data = "10.8.10.1", ttl = 60 },
      { name = "app", type = "A", data = "10.8.10.2", ttl = 60 },
      { name = "@", type = "TXT", data = "\"hello world\"" },
      { name = "opaque", type = "TYPE65280", data = "\\# 2 ABCD" },
    ]
  }
  assert {
    condition = alltrue([
      for line in [
        "greatfox 300 IN A 10.20.7.20",
        "greatfox 300 IN AAAA fd69:20::20",
        "fichina 300 IN A 10.20.7.11",
        "venom 300 IN A 10.20.7.17",
        "www 300 IN CNAME greatfox.lylat.space.",
        "lylat.space. 300 IN MX 10 mail.lylat.space.",
        "lylat.space. 300 IN CAA 0 issue \"letsencrypt.org\"",
        "app 60 IN A 10.8.10.1",
        "app 60 IN A 10.8.10.2",
        "lylat.space. 300 IN TXT \"hello world\"",
        "opaque 300 IN TYPE65280 \\# 2 ABCD",
      ] : strcontains(join("\n", flatten([for r in local.record_payload.rrsets : [for data in r.data : "${trimsuffix(r.name, ".lylat.space.")} ${r.ttl} IN ${r.type} ${data}"]])), line)
    ])
    error_message = "Render generated hosts, custom types, repeated records, TTLs, quoted RDATA and RFC 3597 data."
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
  expect_failures = [terraform_data.dns_records]
}

run "reject_bootstrap_record_override" {
  command = plan
  variables {
    dns_hosts = { dns01 = { A = "10.8.99.1" } }
  }
  expect_failures = [terraform_data.dns_records]
}

run "generate_tsig_by_default" {
  command = plan
  variables {
    dns_tsig_secret = null
  }
  assert {
    condition     = length(random_bytes.dns_tsig) == 1 && random_bytes.dns_tsig[0].length == 32
    error_message = "An unspecified TSIG key must generate a persistent 32-byte random value."
  }
}
