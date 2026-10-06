# Provider source code

```bash
git init
git submodule add git@github.com:houndsolo/terraform-provider-proxmox.git providers/terraform-provider-proxmox
git submodule add git@github.com:houndsolo/vibecoded-opentofu-vyos-provider.git providers/terraform-provider-vyoscmd
git submodule add git@github.com:houndsolo/terraform-provider-routeros.git providers/terraform-provider-routeros
```

These URLs follow the reference repository's current .gitmodules.
The Git URL and the HCL provider source address are separate settings.
Follow each provider's build instructions before adding provider requirements.
