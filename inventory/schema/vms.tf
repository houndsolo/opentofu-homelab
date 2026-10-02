variable "vms" {
  description = "Machine definitions. Each key has one owning root."
  type = map(object({
    owner = string
    node = string
    vm_id = number
    cores = number
    memory_mb = number
    bridge = string
  }))
  validation {
    condition = alltrue([for vm in values(var.vms) : contains(["fabric-vms", "network-services", "workloads"], vm.owner)])
    error_message = "VM owner must be fabric-vms, network-services, or workloads."
  }
  validation {
    condition = alltrue([for vm in values(var.vms) : vm.vm_id >= 100 && vm.vm_id <= 999999999 && floor(vm.vm_id) == vm.vm_id && vm.cores >= 1 && floor(vm.cores) == vm.cores && vm.memory_mb >= 512 && floor(vm.memory_mb) == vm.memory_mb])
    error_message = "VM IDs, cores, and memory must be valid integers."
  }
  validation {
    condition = length(distinct([for vm in values(var.vms) : vm.vm_id])) == length(var.vms)
    error_message = "Each VM ID must be unique in this example cluster."
  }
}
