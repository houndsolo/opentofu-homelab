# proxmox-settings against the real inventory (nodes.auto.tfvars, proxmox-settings.auto.tfvars).
mock_provider "proxmox" {}
mock_provider "proxmox" { alias = "greatfox" }

variables {
  pve_api_token      = "mock"
  greatfox_api_token = "mock"
  import_existing    = false # tofu test can't import through mocked providers
}

run "every_host_gets_dns_and_time" {
  command = plan
  assert {
    condition = (
      length(proxmox_virtual_environment_dns.cluster) == 7 && length(proxmox_virtual_environment_dns.standalone) == 1 &&
      proxmox_virtual_environment_dns.standalone["greatfox"].domain == "lylat.space" &&
      proxmox_virtual_environment_time.cluster["venom"].time_zone == "America/New_York"
    )
    error_message = "All 7 cluster nodes and greatfox get DNS and the time zone; greatfox through its alias."
  }
  assert {
    condition = (
      length(proxmox_cluster_options.cluster) == 1 && proxmox_cluster_options.cluster[0].crs_ha == "dynamic" &&
      proxmox_cluster_options.cluster[0].migration_cidr == "10.22.0.0/16" &&
      length(proxmox_cluster_options.standalone) == 1 && proxmox_cluster_options.standalone[0].language == null
    )
    error_message = "The cluster and greatfox each get their own datacenter options; unset attributes stay unmanaged."
  }
}

run "node_override" {
  command = plan
  variables {
    proxmox_settings = {
      dns       = { domain = "lylat.space", servers = ["10.8.53.53", "1.1.1.1"] }
      time_zone = "America/New_York"
      nodes     = { greatfox = { time_zone = "UTC", dns = { domain = "lylat.space", servers = ["1.1.1.1"] } } }
    }
  }
  assert {
    condition = (
      proxmox_virtual_environment_time.standalone["greatfox"].time_zone == "UTC" &&
      proxmox_virtual_environment_dns.cluster["fichina"].servers == tolist(["10.8.53.53", "1.1.1.1"]) &&
      proxmox_virtual_environment_dns.standalone["greatfox"].servers == tolist(["1.1.1.1"]) &&
      length(proxmox_cluster_options.cluster) == 0
    )
    error_message = "Per-host overrides win over the defaults; no datacenter key = datacenter options unmanaged."
  }
}
