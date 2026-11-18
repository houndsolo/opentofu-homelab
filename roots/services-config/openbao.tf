# OpenBao (secrets store) on the role = "bao" VMs (bao01-03): a 3-node integrated-Raft cluster, https://bao.lylat.space
# through the proxy pair (any node answers: standbys forward to the active node). Design and the decisions behind
# it: vault note planned-projects/openbao-plan.md; how to use it: Instructions/openbao/openbao.md.
#
# - Storage: Raft on each VM's own disk (/var/lib/openbao). Nothing shared: the store must come up when Patroni,
#   Valkey or CephFS are broken. Never point two nodes at one data directory.
# - Unseal: static key (seal "static"), 32 random bytes generated here, kept in this root's encrypted state,
#   0400 on every node. Nodes unseal themselves after any restart; whoever has root on a bao VM (or this state)
#   can decrypt the store (the owner's choice, see the plan note).
# - TLS: the *.lylat.space wildcard from roots/certs (copied to /etc/ssl/svc on the bao VMs too);
#   openbao-tls.path copies it to /etc/openbao/tls for the container's uid and sends SIGHUP on renewal.
# - Self-init (first node only, var.openbao.init_node): kv/ (KV v2), userpass with the owner's login (initial
#   password: output openbao_initial_password), the admin policy, AppRole, and the snapshot AppRole. Runs once,
#   on the very first start of an empty cluster; the root token it uses is revoked. Recovery keys don't exist
#   until the owner runs `bao operator rotate-keys -target=recovery -init ...` (Instructions note).
# - Audit: declarative audit device to stdout = the journal -> Loki (API-created devices are refused by 2.x).
# - Snapshots: openbao-snapshot.timer on every node, 03:15; only the active node saves, keeps 14 days in
#   /var/lib/openbao-snapshots (+ PBS VM backups). A snapshot + the seal key = the whole store: keep apart.
#
# Order: services-vms -> certs (the wildcard on the bao VMs) -> services-config (init node first, then the rest).
variable "openbao" {
  description = "OpenBao on the role = \"bao\" VMs: domain, first node (self-init), owner login. null = don't deploy."
  type = object({
    domain    = optional(string, "lylat.space")
    init_node = optional(string, "bao01")        # self-initializes the cluster; must sort first (canary)
    owner     = optional(string, "houndsolo")    # userpass login with the admin policy
    seal_key  = optional(string, "tofu-1")       # current_key_id of the static seal; change only when rotating
    cert_dir  = optional(string, "/etc/ssl/svc") # = roots/certs var.certificate.directory
  })
  default = {}
}

resource "random_bytes" "openbao_seal" {
  count  = local.openbao_enabled ? 1 : 0
  length = 32
}

resource "random_password" "openbao_initial" {
  count   = local.openbao_enabled ? 1 : 0
  length  = 24
  special = false
}

resource "random_password" "openbao_snapshot" {
  count   = local.openbao_enabled ? 1 : 0
  length  = 40
  special = false
}

locals {
  openbao_vms     = { for name, vm in var.vms : name => vm if vm.owner == "services-vms" && vm.role == "bao" }
  openbao_names   = sort(keys(local.openbao_vms))
  openbao_enabled = var.openbao != null && length(local.openbao_vms) > 0

  # The proxies' addresses on the nodes' VLAN (lylat-app): trusted for X-Forwarded-For in the audit log.
  openbao_proxies = sort(flatten([for vm in values(local.proxy_vms) : [for nic in vm.network_devices : split("/", nic.ipv4_address)[0] if nic.ipv4_address != null && nic.vlan_id == 1201]]))

  openbao_files = {
    for name, vm in(!local.openbao_enabled ? {} : local.openbao_vms) : name => [
      { path = "/etc/openbao/config/bao.hcl", mode = "0640", owner = "100:1000", units = ["openbao"], restart = true, content = templatefile("${path.module}/templates/openbao.hcl.tftpl", {
        name       = name
        domain     = var.openbao.domain
        peers      = [for n in local.openbao_names : n if n != name]
        proxies    = local.openbao_proxies
        key_id     = var.openbao.seal_key
        initialize = name == var.openbao.init_node
        owner      = var.openbao.owner
      }) },
      { path = "/etc/openbao/seal/unseal.key", mode = "0400", owner = "100:1000", units = ["openbao"], restart = true, content = random_bytes.openbao_seal[0].hex },
      { path = "/etc/openbao/openbao.env", mode = "0600", units = ["openbao"], restart = true, content = join("", [
        "BAO_SNAPSHOT_SECRET_ID=${random_password.openbao_snapshot[0].result}\n",
        name == var.openbao.init_node ? "BAO_INITIAL_PASSWORD=${random_password.openbao_initial[0].result}\n" : "",
      ]) },
      { path = "/etc/systemd/system/openbao-tls.service", units = ["openbao-tls.path"], content = <<-EOT
        # Managed by OpenTofu (services-config, openbao.tf): the wildcard certificate for the container's uid.
        [Unit]
        Description=OpenBao TLS certificate copy (from ${var.openbao.cert_dir})
        [Service]
        Type=oneshot
        ExecStart=/usr/bin/install -m 0644 -o 100 -g 1000 ${var.openbao.cert_dir}/fullchain.pem /etc/openbao/tls/fullchain.pem
        ExecStart=/usr/bin/install -m 0600 -o 100 -g 1000 ${var.openbao.cert_dir}/privkey.pem /etc/openbao/tls/privkey.pem
        # OpenBao reloads its listener certificate on SIGHUP (no restart); fine if it isn't running yet.
        ExecStartPost=-/usr/bin/podman kill --signal HUP openbao
        EOT
      },
      { path = "/etc/systemd/system/openbao-tls.path", units = ["openbao-tls.path"], content = <<-EOT
        # Managed by OpenTofu (services-config, openbao.tf). roots/certs installs privkey.pem last on renewal.
        [Unit]
        Description=Watch the wildcard certificate for OpenBao
        [Path]
        PathChanged=${var.openbao.cert_dir}/privkey.pem
        Unit=openbao-tls.service
        [Install]
        WantedBy=multi-user.target
        EOT
      },
      { path = "/etc/openbao/bin/snapshot.sh", mode = "0755", content = <<-EOT
        #!/bin/sh
        # Managed by OpenTofu (services-config, openbao.tf). Runs inside the container (openbao-snapshot.service).
        set -eu
        export BAO_ADDR=https://127.0.0.1:8200 BAO_SKIP_VERIFY=true
        # Only the active node saves a snapshot.
        wget -q -O - --no-check-certificate "$BAO_ADDR/v1/sys/leader" | grep -q '"is_self":true' || { echo "standby: no snapshot"; exit 0; }
        BAO_TOKEN=$(bao write -field=token auth/approle/login role_id=snapshot secret_id="$BAO_SNAPSHOT_SECRET_ID")
        export BAO_TOKEN
        f=/openbao/snapshots/bao-$(date -u +%Y%m%dT%H%M%SZ).snap
        bao operator raft snapshot save "$f"
        bao token revoke -self >/dev/null 2>&1 || true
        find /openbao/snapshots -name 'bao-*.snap' -mtime +14 -delete
        echo "saved $f ($(wc -c < "$f") bytes)"
        EOT
      },
      { path = "/etc/systemd/system/openbao-snapshot.service", content = <<-EOT
        # Managed by OpenTofu (services-config, openbao.tf).
        [Unit]
        Description=OpenBao raft snapshot (active node only)
        Requires=openbao.service
        After=openbao.service
        [Service]
        Type=oneshot
        ExecStart=/usr/bin/podman exec openbao sh /openbao/bin/snapshot.sh
        EOT
      },
      { path = "/etc/systemd/system/openbao-snapshot.timer", units = ["openbao-snapshot.timer"], content = <<-EOT
        # Managed by OpenTofu (services-config, openbao.tf).
        [Unit]
        Description=Nightly OpenBao raft snapshot
        [Timer]
        OnCalendar=*-*-* 03:15:00
        RandomizedDelaySec=5m
        Persistent=true
        [Install]
        WantedBy=timers.target
        EOT
      },
      { path = "/etc/containers/systemd/openbao.container", units = ["openbao"], content = templatefile("${path.module}/templates/openbao.container.tftpl", {
        name  = name
        image = local.container_images.openbao
      }) },
    ]
  }

  openbao_health = "https://127.0.0.1:8200/v1/sys/health?standbyok=true"

  openbao_canary = { for name, f in local.openbao_files : name => f if name == var.openbao.init_node }
  openbao_rest   = { for name, f in local.openbao_files : name => f if name != var.openbao.init_node }
}

check "openbao_init_node" {
  assert {
    condition     = !local.openbao_enabled || (contains(local.openbao_names, var.openbao.init_node) && local.openbao_names[0] == var.openbao.init_node && length(local.openbao_names) % 2 == 1)
    error_message = "openbao: init_node must be a bao VM and sort first (it deploys first), and the cluster needs an odd number of nodes (Raft quorum)."
  }
}

module "openbao" {
  source   = "../../modules/services/quadlet-deploy"
  for_each = local.openbao_files

  name     = "openbao"
  host     = each.key
  files    = each.value
  units    = ["openbao-tls.path", "openbao", "openbao-snapshot.timer"]
  images   = [local.container_images.openbao]
  packages = ["curl"]
  setup = [
    # The wildcard certificate comes from roots/certs.
    "for f in '${var.openbao.cert_dir}/fullchain.pem' '${var.openbao.cert_dir}/privkey.pem'; do [ -s \"$f\" ] || { echo \"missing $f: apply roots/certs first\" >&2; exit 1; }; done",
  ]
  checks = concat([
    # The staged config, seal key and the certificate it names (as root: the key files are 0600/0400).
    "podman run --rm --network none --user 0 --entrypoint bao -v \"$stage/etc/openbao/config:/openbao/config:ro\" -v \"$stage/etc/openbao/seal:/openbao/seal:ro\" -v '${var.openbao.cert_dir}:/openbao/tls:ro' '${local.container_images.openbao}' operator validate-config -config=/openbao/config/bao.hcl",
    ], each.key == var.openbao.init_node ? [
    # Rebuilt init node with empty storage while the others still form a cluster: self-init would start a
    # SECOND cluster. Refuse; join it instead (set openbao.init_node to a node that doesn't exist, e.g. "none").
    "if [ ! -e /var/lib/openbao/raft/raft.db ]; then for p in ${join(" ", [for n in local.openbao_names : "${n}.${var.openbao.domain}" if n != each.key])}; do if curl -sk --max-time 3 \"https://$p:8200/v1/sys/seal-status\" | grep -q '\"initialized\":true'; then echo \"$p is already initialized: refusing to self-init a second cluster on ${each.key}\" >&2; exit 1; fi; done; fi",
  ] : [])
  dirs = [
    { path = "/var/lib/openbao", mode = "0700", owner = "100:1000" },
    { path = "/var/lib/openbao-snapshots", mode = "0700", owner = "100:1000" },
    { path = "/etc/openbao", mode = "0755" },
    { path = "/etc/openbao/config", mode = "0750", owner = "100:1000" },
    { path = "/etc/openbao/seal", mode = "0700", owner = "100:1000" },
    { path = "/etc/openbao/tls", mode = "0750", owner = "100:1000" },
    { path = "/etc/openbao/bin", mode = "0755" },
  ]
  post_install = [
    "systemctl start openbao-tls.service",
  ]
  verify = [
    # Unsealed (active or standby) on this node.
    "retry sh -c \"curl -sk --max-time 5 -o /dev/null -w '%%{http_code}' '${local.openbao_health}' | grep -qx 200\"",
    "curl -sk --max-time 5 https://127.0.0.1:8200/v1/sys/health?standbyok=true | grep -oE '\\\"(initialized|sealed|standby|version)\\\":[^,]+' | tr '\\n' ' '; echo",
  ]
}

resource "terraform_data" "openbao_canary" {
  for_each = local.openbao_canary
  # The nodes find each other by name (retry_join https://baoNN.lylat.space:8200).
  depends_on = [dns_a_record_set.records]

  triggers_replace = [
    sha256(module.openbao[each.key].script),
    local.openbao_vms[each.key].management_address,
    local.openbao_vms[each.key].vm_id,
  ]

  connection {
    type        = "ssh"
    host        = split("/", local.openbao_vms[each.key].management_address)[0]
    user        = local.openbao_vms[each.key].config.ssh_username
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = ["install -d -m 0700 /tmp/tofu-openbao-${self.id}"]
  }

  provisioner "file" {
    content     = module.openbao[each.key].script
    destination = "/tmp/tofu-openbao-${self.id}/deploy.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "rc=0; sudo -n bash /tmp/tofu-openbao-${self.id}/deploy.sh || rc=$?; rm -rf /tmp/tofu-openbao-${self.id}; exit $rc",
    ]
  }
}

resource "terraform_data" "openbao" {
  for_each   = local.openbao_rest
  depends_on = [terraform_data.openbao_canary]

  triggers_replace = [
    sha256(module.openbao[each.key].script),
    local.openbao_vms[each.key].management_address,
    local.openbao_vms[each.key].vm_id,
  ]

  connection {
    type        = "ssh"
    host        = split("/", local.openbao_vms[each.key].management_address)[0]
    user        = local.openbao_vms[each.key].config.ssh_username
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = ["install -d -m 0700 /tmp/tofu-openbao-${self.id}"]
  }

  provisioner "file" {
    content     = module.openbao[each.key].script
    destination = "/tmp/tofu-openbao-${self.id}/deploy.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "rc=0; sudo -n bash /tmp/tofu-openbao-${self.id}/deploy.sh || rc=$?; rm -rf /tmp/tofu-openbao-${self.id}; exit $rc",
    ]
  }
}

output "openbao_url" {
  description = "OpenBao: the public URL, the owner's login and each node's API."
  value = !local.openbao_enabled ? {} : merge(
    { public = "https://bao.${var.openbao.domain}/ (userpass ${var.openbao.owner}; initial password: tofu output -raw openbao_initial_password)" },
    { for n in local.openbao_names : n => "https://${n}.${var.openbao.domain}:8200" },
  )
}

output "openbao_initial_password" {
  description = "Initial password of the owner's OpenBao userpass login (self-init only; change it after the first login)."
  value       = local.openbao_enabled ? random_password.openbao_initial[0].result : null
  sensitive   = true
}
