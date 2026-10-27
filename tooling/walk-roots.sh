#!/usr/bin/env bash
# Guided local-state workflow. Run from any directory.
set -euo pipefail
umask 077
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo"
roots=(proxmox-download-files proxmox-network fabric-vms fabric-spines fabric-leaves services-vms services-config workloads)
usage() {
  cat <<'EOF'
Usage: tooling/walk-roots.sh [--no-secrets] [--list] [ROOT ...]

Walk all usable roots in dependency order, or only the named roots.
At each root: plan, plan then apply, skip, or quit. Services-config also
has a DNS bootstrap choice; use it once before its first normal apply.

Uses tooling/with-secrets when the central passwords file exists.
--no-secrets uses your existing TF_VAR_* environment instead.
Set TOFU_BIN to select an OpenTofu executable.
Example: TF_VAR_ssh_private_key_path=~/.ssh/id_ed25519 tooling/walk-roots.sh services-config

proxmox-settings is incomplete; proxmox-virtual-hosts is empty. Both are excluded.
EOF
}
use_secrets=true
selected=()
while (($#)); do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --list) printf '%s\n' "${roots[@]}"; exit 0 ;;
    --no-secrets) use_secrets=false ;;
    --*) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
    *) selected+=("$1") ;;
  esac
  shift
done
for root in "${selected[@]}"; do
  found=false
  for candidate in "${roots[@]}"; do [[ $root != "$candidate" ]] || found=true; done
  if [[ $found == false ]]; then printf 'Unknown or unfinished root: %s\n' "$root" >&2; exit 2; fi
done
tofu=${TOFU_BIN:-tofu}
command -v "$tofu" >/dev/null || { echo 'OpenTofu is missing. Run nix-shell first.' >&2; exit 1; }
command_prefix=()
if [[ $use_secrets == true && -f inventory/auto.tfvars/passwords.secret.auto.tfvars ]]; then
  command_prefix=("$repo/tooling/with-secrets" --tofu "$tofu" --)
fi
run_tofu() { "${command_prefix[@]}" "$tofu" "-chdir=$repo/roots/$root" "$@"; }
plan_dir=''
trap '[[ -z $plan_dir ]] || rm -rf -- "$plan_dir"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
printf 'Each root has separate state. Build providers and set TF_CLI_CONFIG_FILE first.\n'
for root in "${roots[@]}"; do
  if ((${#selected[@]})); then
    found=false
    for candidate in "${selected[@]}"; do [[ $root != "$candidate" ]] || found=true; done
    [[ $found == true ]] || continue
  fi
  printf '\n--- %s ---\n' "$root"
  case "$root" in
    proxmox-download-files) echo 'Optional image download. Skip if your customized QCOW2 already exists.' ;;
    proxmox-network) echo 'Host networking: review bridge, bond and VLAN changes carefully.' ;;
    fabric-vms) echo 'Create fabric VMs; the VyOS image and snippets must already exist.' ;;
    fabric-spines) echo 'Configure RouterOS spines; their APIs must be reachable.' ;;
    fabric-leaves) echo 'Configure VyOS leaves after enabling their HTTPS APIs.' ;;
    services-vms) echo 'Create DNS/DHCP VMs; images, snippets and fabric must be ready.' ;;
    services-config) echo 'DNS VMs need SSH/sudo and Podman; DHCP VMs need reachable VyOS APIs.' ;;
    workloads) echo 'Create VMs owned by workloads.' ;;
  esac
  while true; do
    prompt='[p]lan, [a]pply, [s]kip (default), [q]uit'
    [[ $root != services-config ]] || prompt+=', [b]ootstrap DNS'
    read -r -p "$prompt: " choice || exit 0
    case "$choice" in
      ''|s|S) break ;;
      q|Q) exit 0 ;;
      p|P|a|A) ;;
      b|B) [[ $root == services-config ]] || { echo 'Bootstrap is only for services-config.'; continue; } ;;
      *) echo 'Choose p, a, s or q (b for DNS bootstrap).'; continue ;;
    esac
    run_tofu init -input=false
    run_tofu validate
    plan_dir=$(mktemp -d "${TMPDIR:-/tmp}/tofu-walk.XXXXXXXX")
    plan_args=(-input=false -detailed-exitcode "-out=$plan_dir/plan")
    [[ $choice != b && $choice != B ]] || plan_args+=(-target=terraform_data.bind9)
    status=0
    run_tofu plan "${plan_args[@]}" || status=$?
    if ((status != 0 && status != 2)); then
      echo 'Plan failed; stopping before later roots.' >&2
      exit "$status"
    fi
    if ((status == 2)) && [[ $choice != p && $choice != P ]]; then
      read -r -p 'Apply the plan shown above? Type yes: ' answer || exit 0
      if [[ $answer == yes ]]; then run_tofu apply -input=false "$plan_dir/plan"; fi
    fi
    rm -rf -- "$plan_dir"
    plan_dir=''
    if [[ $choice == b || $choice == B ]]; then
      echo 'Choose normal apply next to manage DNS records and DHCP.'
      continue
    fi
    break
  done
done
printf '\nWalk complete. Skipped roots were not changed.\n'
