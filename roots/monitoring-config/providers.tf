terraform {
  required_version = ">= 1.9.0"
  required_providers {
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
    # Buckets and write tokens for the Proxmox metric servers (InfluxDB 2 API on mon01).
    influxdb = {
      source  = "komminarlabs/influxdb"
      version = "~> 1.0"
    }
    proxmox = {
      source  = "local/mechanic/proxmox"
      version = "0.111.0"
    }
  }
}

locals {
  pve_management_ips = { for name, node in var.nodes.proxmox : name => cidrhost(var.nodes.management_prefix, node.id) }
  pve_api_node       = coalesce(var.pve_api_node, var.nodes.cluster_api_node)
  standalone_pve     = [for name, node in var.nodes.proxmox : name if node.standalone]
}

# The InfluxDB operator token generated here (random_password.influxdb_token), on
# mon01's monitoring-network address. mon01 must be deployed before anything in
# pve-metrics.tf can be planned against it.
provider "influxdb" {
  url   = "http://${coalesce(try(local.monitoring_address[local.backend_name], null), "0.0.0.0")}:8086"
  token = random_password.influxdb_token.result
}

provider "proxmox" {
  endpoint  = "https://${local.pve_management_ips[local.pve_api_node]}:8006"
  api_token = var.pve_api_token
  insecure  = true
}

# The standalone host (nodes.proxmox[*].standalone), which has its own API and metric server config.
provider "proxmox" {
  alias     = "greatfox"
  endpoint  = "https://${try(local.pve_management_ips[local.standalone_pve[0]], "0.0.0.0")}:8006"
  api_token = var.greatfox_api_token
  insecure  = true
}
