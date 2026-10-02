variable "name" {
  type = string
  description = "Stable machine name, supplied by the root's for_each key."
}
variable "vm" {
  type = object({
    node = string
    vm_id = number
    cores = number
    memory_mb = number
    bridge = string
  })
  description = "Configuration for one machine."
}
