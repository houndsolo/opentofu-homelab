output "vm_specifications" {
  value = { for name, vm in module.vm : name => vm.specification }
  precondition {
    condition = alltrue([for vm in values(local.selected_vms) : contains(keys(var.nodes), vm.node)])
    error_message = "Each selected VM must use a node from nodes.auto.tfvars."
  }
}
