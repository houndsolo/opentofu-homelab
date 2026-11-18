module "leaves" {
  source = "../../modules/fabric/leaves"
  fabric = var.fabric
  nodes  = var.nodes
}

locals {
  leaves = module.leaves.leaves
}
