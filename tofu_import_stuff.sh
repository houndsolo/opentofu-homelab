#!/usr/bin/env bash
set -euo pipefail

root_dir="$PWD/roots/proxmox-network"

[[ -f "$root_dir/main.tf" ]] || {
  printf 'Run this script from the project’s top-level directory.\n' >&2
  exit 1
}

nodes=(
  fichina
  fortuna
  macbeth
  titania
  zoness
  venom
  eldarad
)

bridges=(1 0 100 7 4000 4001 4002 4010 4011 4012 22 27)
eths=(0 1 10 7 4001 4002 22 27)
bonds=(0)

# VLAN ID followed by its parent interface.
vlans=(
  "2 vmbr4000"
  "22 bond0"
  "27 bond0"
)

import_resource() {
  local address="$1"
  local import_id="$2"

  printf '\nImporting %s as %s\n' "$import_id" "$address"
  tofu -chdir="$root_dir" import "$address" "$import_id"
}

for node in "${nodes[@]}"; do
  for eth in "${eths[@]}"; do
    import_resource \
      "module.pve_network[\"${node}\"].proxmox_network_linux_eth.this[\"${eth}\"]" \
      "${node}:eth${eth}"
  done

  for bond in "${bonds[@]}"; do
    import_resource \
      "module.pve_network[\"${node}\"].proxmox_network_linux_bond.this[\"${bond}\"]" \
      "${node}:bond${bond}"
  done

  for br in "${bridges[@]}"; do
    import_resource \
      "module.pve_network[\"${node}\"].proxmox_network_linux_bridge.this[\"${br}\"]" \
      "${node}:vmbr${br}"
  done

  for vlan_pair in "${vlans[@]}"; do
    read -r vlan_id parent_interface <<< "$vlan_pair"

    import_resource \
      "module.pve_network[\"${node}\"].proxmox_network_linux_vlan.this[\"${vlan_id}\"]" \
      "${node}:${parent_interface}.${vlan_id}"
  done
done
