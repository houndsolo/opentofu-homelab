# Workload VMs

Creates entries in `inventory/auto.tfvars/vms.auto.tfvars` with
`owner = "workloads"`, using the shared VM module, named images and SSH keys.
Host networking and selected images must already exist.

```sh
tooling/walk-roots.sh workloads
```
