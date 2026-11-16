# Renders the deploy script (plan only: nothing is contacted) and checks its shape.
variables {
  hosts                  = { mon-test = { address = "192.0.2.10" } }
  images                 = { prometheus = "example/prometheus:1", grafana = "example/grafana:1", node_exporter = "example/node-exporter:1" }
  scrape_targets         = { node = ["192.0.2.10:9100"] }
  grafana_admin_password = "test"
  ssh_private_key_path   = "tests/render.tftest.hcl" # any readable file: plan never connects
}

run "render" {
  command = plan

  assert {
    condition     = length(regexall("(?m)^put '", local.deploy_script["mon-test"])) == length(local.files)
    error_message = "One put line per file."
  }
  assert {
    condition     = strcontains(local.deploy_script["mon-test"], "put '/etc/monitoring/grafana.env' '0600' 'grafana'")
    error_message = "The env file is installed 0600 and belongs to grafana."
  }
  assert {
    condition     = !strcontains(nonsensitive(local.deploy_script["mon-test"]), "GF_SECURITY_ADMIN_PASSWORD=test")
    error_message = "File contents are base64 in the script, not plain text."
  }
  assert {
    condition     = strcontains(local.deploy_script["mon-test"], "for unit in monitoring-network prometheus grafana node-exporter; do")
    error_message = "Units start in the listed order."
  }
}
