# Exercise initial key generation with the real DNS/random providers.
# Plan only: no DNS requests, SSH, or Proxmox changes are performed.
mock_provider "proxmox" {
  mock_resource "proxmox_virtual_environment_file" {
    defaults = { id = "cephfs:snippets/mock-user-data.yaml" }
  }
  mock_resource "proxmox_download_file" {
    defaults = { id = "cephfs:import/debian-test.qcow2" }
  }
}
mock_provider "proxmox" { alias = "greatfox" }
variables {
  pve_api_token        = "mock-only"
  gf_api_token         = "mock-only"
  ssh_private_key_path = "tests/fixtures/id_test"
}
run "first_plan_with_generated_key" { command = plan }
