network_services = {
  dhcp = {
    dhcp1 = { node = "titania", vm_id = 6701, management_address = "10.20.10.251/16" }
    dhcp2 = { node = "zoness", vm_id = 6702, management_address = "10.20.10.252/16" }
  }
  dns = {
    dns1 = { node = "fichina", vm_id = 5301, management_address = "10.20.53.1/16", service_address = "10.8.53.1/16" }
    dns2 = { node = "fortuna", vm_id = 5302, management_address = "10.20.53.2/16", service_address = "10.8.53.2/16" }
  }
}
