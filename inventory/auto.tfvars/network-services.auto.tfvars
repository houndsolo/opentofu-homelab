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

debian_image = {
  url       = "https://cloud.debian.org/images/cloud/trixie/20261001-2618/debian-13-genericcloud-amd64-20261001-2618.qcow2"
  file_name = "debian-13-genericcloud-amd64-20261001-2618.qcow2"
  checksum  = "f46f0671a6e5bdec5291ab8972bae2f10e5408c2f64a74078f11efc2f06a436a9d0313ed50e0472542eeabf780e9f7c792ac0a314c6c20507fcd9fd81b468c3d"
}
