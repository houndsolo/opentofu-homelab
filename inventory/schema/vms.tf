variable "vms" {
  description = "Machine definitions. Each key has one owning root."
  type = map(object({
    owner     = string
    node      = string
    vm_id     = number
    cores     = number
    memory_mb = number
    bridge    = string
  }))
}
