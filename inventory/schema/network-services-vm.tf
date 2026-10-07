variable "network_services_vm" {
  description = "Minimal VM template shared by DNS and DHCP guests."
  type = object({
    cpu_cores               = optional(number, 2)
    memory_mb               = optional(number, 2048)
    disk_size_gb            = optional(number, 10)
    datastore_id            = optional(string, "ceph_rbd")
    cloud_init_datastore_id = optional(string, "ceph_rbd")
    management_bridge       = optional(string, "vmbr0")
    started                 = optional(bool, true)
  })
}
