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
  checksum  = "6f0f93335bdef4ccf523c4317cc663ea52ca23b862667785f3d6d186ab4674a937385ccff0c55996b4b2e4c19e440cdf211e2a75ffa2f6548037ab43950c841d"
}
