# Let's Encrypt certificates for the proxy pair (proxy01/02): *.lylat.space via the Cloudflare
# DNS-01 challenge (vancluever/acme), copied to the proxies over SSH. Renewal runs from a daily
# scheduled apply. State and plans are encrypted (state-encryption.tf): they hold the private keys.
terraform {
  required_version = ">= 1.13.0"

  required_providers {
    acme = {
      source  = "vancluever/acme"
      version = "~> 3.3.0" # 3.0 moved to lego v5 and renamed arguments: read the changelog before bumping
    }
  }
}

locals {
  acme_servers = {
    staging    = "https://acme-staging-v02.api.letsencrypt.org/directory"
    production = "https://acme-v02.api.letsencrypt.org/directory"
  }

  # VMs from the shared inventory that get the certificate: the proxies (nginx) and the OpenBao nodes
  # (their API/cluster listener, services-config openbao.tf; a path unit there copies it for the container).
  cert_vms = { for name, vm in var.vms : name => vm if vm.owner == "services-vms" && contains(["proxy", "bao"], vm.role) }
}

provider "acme" {
  server_url = local.acme_servers[var.acme_server]
}
