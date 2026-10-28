module "leaves" {
  source = "../../modules/fabric/leaves"
  fabric = var.fabric
  nodes  = var.nodes
}

locals {
  # tooling/routeros-spine-imports.py reads this local.
  leaves = module.leaves.leaves
}
