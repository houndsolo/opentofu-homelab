output "leaf_specifications" {
  value = { for name, leaf in module.leaf : name => leaf.specification }
}
