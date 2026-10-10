module "defaults" {
  source    = "./defaults"
  name      = var.name
  vm        = var.vm
  vm_config = var.vm_config
  vm_images = var.vm_images
}

locals {
  config = module.defaults.config
}
