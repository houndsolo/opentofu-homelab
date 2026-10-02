# Second exercise: add VyOS interface and BGP resources here.
# Add peer definitions to the schema before you configure sessions.
locals {
  specification = merge(var.leaf, {
    name = var.name
    overlay_as = var.overlay_as
  })
}
