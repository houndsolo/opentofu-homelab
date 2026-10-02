# First exercise: add a Proxmox VM resource here.
# This module currently computes an output only.
locals {
  specification = merge(var.vm, { name = var.name })
}
