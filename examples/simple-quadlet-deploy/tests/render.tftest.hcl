# Renders the deploy scripts (plan only: nothing is contacted) and checks their shape.
variables {
  hosts = {
    mon-test  = { role = "prometheus", address = "192.0.2.10" }
    graf-test = { role = "grafana", address = "192.0.2.20" }
  }
  images                 = { prometheus = "example/prometheus:1", grafana = "example/grafana:1", node_exporter = "example/node-exporter:1" }
  grafana_admin_password = "test"
  ssh_private_key_path   = "tests/render.tftest.hcl" # any readable file: plan never connects
}

run "render" {
  command = plan

  assert {
    condition     = strcontains(local.deploy_script["mon-test"], "for unit in prometheus node-exporter; do")
    error_message = "The prometheus VM runs prometheus and node-exporter, in that order."
  }
  assert {
    condition     = strcontains(local.deploy_script["graf-test"], "for unit in grafana node-exporter; do")
    error_message = "The grafana VM runs grafana and node-exporter, in that order."
  }
  assert {
    condition     = !strcontains(local.deploy_script["mon-test"], "grafana") && !strcontains(local.deploy_script["graf-test"], "prometheus.container")
    error_message = "A VM gets only its own role's files."
  }
  assert {
    condition     = strcontains(local.deploy_script["graf-test"], "put '/etc/grafana/grafana.env' '0600' 'grafana'")
    error_message = "The env file is installed 0600 and belongs to grafana."
  }
  assert {
    condition     = !strcontains(nonsensitive(local.deploy_script["graf-test"]), "GF_SECURITY_ADMIN_PASSWORD=test")
    error_message = "File contents are base64 in the script, not plain text."
  }
  assert {
    condition     = strcontains(local.datasources_yml, "http://192.0.2.10:9090")
    error_message = "Grafana's datasource points at the prometheus VM."
  }
}
