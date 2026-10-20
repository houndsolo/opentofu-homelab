variables {
  ssh_private_key_path = "/dev/null"
}

run "dns_rollout_plan" {
  command = plan

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
