locals {
  image_config = var.vm.image == null ? null : var.vm_images[var.vm.image]
  config = merge(
    var.vm_config,
    local.image_config == null ? {} : {
      import_image      = local.image_config.import_image
      user_data_file_id = local.image_config.user_data_file_id
    },
    local.image_config == null ? {} : {
      for key, value in { tags = local.image_config.tags } : key => value if value != null
    },
    { for key, value in {
      cpu_cores         = var.vm.cores
      memory_mb         = var.vm.memory_mb
      management_bridge = var.vm.bridge
      started           = var.vm.started
      tags              = var.vm.tags
    } : key => value if value != null },
    { for key, value in var.vm.config : key => value if value != null },
  )
}
