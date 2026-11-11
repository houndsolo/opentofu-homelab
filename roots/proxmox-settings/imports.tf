# Adopt the settings that already exist on the hosts: the first plan imports them (and shows any
# difference from proxmox-settings.auto.tfvars as an in-place update). Once in state these blocks
# are no-ops. Set import_existing = false only where imports can't run (tofu test with mocks).
variable "import_existing" {
  description = "Import the existing datacenter options, DNS and time zone settings (true outside tests)."
  type        = bool
  default     = true
}

import {
  for_each = var.import_existing && local.dc_cluster != null ? toset(["cluster"]) : toset([])
  to       = proxmox_cluster_options.cluster[0]
  id       = "cluster"
}

import {
  for_each = var.import_existing && local.dc_standalone != null ? toset(["standalone"]) : toset([])
  provider = proxmox.greatfox
  to       = proxmox_cluster_options.standalone[0]
  id       = "cluster"
}

import {
  for_each = var.import_existing ? local.cluster_dns : {}
  to       = proxmox_virtual_environment_dns.cluster[each.key]
  id       = each.key
}

import {
  for_each = var.import_existing ? local.standalone_dns : {}
  provider = proxmox.greatfox
  to       = proxmox_virtual_environment_dns.standalone[each.key]
  id       = each.key
}

import {
  for_each = var.import_existing ? toset(local.cluster_nodes) : toset([])
  to       = proxmox_virtual_environment_time.cluster[each.key]
  id       = each.key
}

import {
  for_each = var.import_existing && local.standalone != null ? toset([local.standalone]) : toset([])
  provider = proxmox.greatfox
  to       = proxmox_virtual_environment_time.standalone[each.key]
  id       = each.key
}
