# Renders a script (no providers, nothing contacted) and checks its shape.
variables {
  name = "example"
  host = "vm01"
  files = [
    { path = "/etc/containers/systemd/app.container", content = "[Container]\nImage=example/app:1\n", units = ["app"] },
    { path = "/etc/app/app.yml", content = "a: 1\n", units = ["app"] },
    { path = "/etc/app/env", content = "TOKEN=secret-value\n", mode = "0600", units = ["app", "app-worker"], restart = true },
    { path = "/var/lib/app/seed.db", content = "seed\n", once = true },
    { path = "/etc/systemd/system/app-guard.service", content = "[Service]\nExecStart=/bin/true\n", units = ["app-guard"] },
  ]
  units      = ["app-guard", "app", "app-worker"]
  dirs       = [{ path = "/var/lib/app", mode = "0750", owner = "472:0" }]
  images     = ["example/app:1"]
  packages   = ["keepalived"]
  checks     = ["test -s \"$stage/etc/app/app.yml\""]
  verify     = ["retry curl -fsS http://127.0.0.1:8080/"]
  prune_dirs = ["/etc/app/dashboards"]
}

run "render" {
  command = plan

  assert {
    condition     = strcontains(nonsensitive(output.script), "put '/etc/containers/systemd/app.container' '0644' '0:0' restart app\n")
    error_message = "A Quadlet file restarts its unit."
  }
  assert {
    condition     = strcontains(nonsensitive(output.script), "put '/etc/app/app.yml' '0644' '0:0' reload app\n")
    error_message = "A config file reloads its unit."
  }
  assert {
    condition     = strcontains(nonsensitive(output.script), "put '/etc/app/env' '0600' '0:0' restart app app-worker\n")
    error_message = "restart = true forces a restart, for every unit of the file."
  }
  assert {
    condition     = strcontains(nonsensitive(output.script), "put '/etc/systemd/system/app-guard.service' '0644' '0:0' restart app-guard\n")
    error_message = "A host unit file restarts its unit."
  }
  assert {
    condition     = strcontains(nonsensitive(output.script), "printf '%s\\n' '/etc/containers/systemd/app.container' '/etc/systemd/system/app-guard.service' > \"$state\"")
    error_message = "Only unit files are tracked for removal."
  }
  assert {
    condition     = strcontains(nonsensitive(output.script), "put '/var/lib/app/seed.db' '0644' '0:0' once \n")
    error_message = "once = true is passed to put."
  }
  assert {
    condition     = strcontains(nonsensitive(output.script), "install -d -m '0750' -o '472' -g '0' '/var/lib/app'")
    error_message = "Directories get their numeric owner."
  }
  assert {
    condition     = !strcontains(nonsensitive(output.script), "secret-value")
    error_message = "File contents are base64 in the script, not plain text."
  }
  assert {
    condition     = strcontains(nonsensitive(output.script), "for unit in app-guard app app-worker; do")
    error_message = "Units start in the listed order."
  }
}
