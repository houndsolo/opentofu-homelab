# certs

Let's Encrypt certificates for the reverse proxy pair (`proxy01`/`proxy02`, role `proxy` in
[`vms.auto.tfvars`](../../inventory/auto.tfvars/vms.auto.tfvars)): one wildcard
`*.lylat.space`, validated with the Cloudflare DNS-01 challenge, copied to every proxy VM. nginx
uses it for https://grafana.lylat.space, netbox, dark-triage and any later proxied name.

| File | What |
| --- | --- |
| `certificate.tf` | ACME account (`acme_registration`) and the certificate (`acme_certificate.svc`) |
| `deploy.tf` | copies `fullchain.pem` (0644) and `privkey.pem` (0600, root) to `/etc/ssl/svc/` on each proxy over SSH, reloads nginx if it runs |
| `state-encryption.tf` | link to the shared state/plan encryption: this state holds the account and certificate keys |
| `*.secret.auto.tfvars` | links to `inventory/auto.tfvars.secret/`: `cloudflare` (API token, Zone:DNS:Edit on lylat.space) and `state_passphrase` |

Order: after services-vms (the proxies must exist), before services-config (nginx expects the
certificate on its first start).

## Renewal

`acme_certificate` only renews during a plan/apply: with `use_renewal_info` (Let's Encrypt's
renewal window) or, without one, once a third of the lifetime is left (`min_days_dynamic`). A
daily scheduled `tofu -chdir=roots/certs apply` from a clean worktree does that; a renewal changes
the serial, which re-runs the deploy. Lifetimes: 90 days today, 64 from 2027-02-10, 45 from
2028-02-16.

## Split-horizon DNS

a0-nix resolves `lylat.space` through dns01/dns02, which are authoritative for the internal zone
and never see Cloudflare's `_acme-challenge` TXT records. `recursive_nameservers` points the
propagation check at 1.1.1.1/1.0.0.1 instead; without it every issue/renew waits two minutes and
fails.

## Switching between staging and production

`acme_server` defaults to `production`. Staging (untrusted certificates, generous rate limits) is
for testing changes to this root: the first certificate was issued there on 2026-11-13 before the
switch. Switch by destroying the current objects first, so the account is never deactivated
against the wrong server:

```
tofu -chdir=roots/certs destroy                 # account + cert, deploy records (files stay on the VMs)
tofu -chdir=roots/certs apply -var acme_server=staging    # or production (the default)
```

The destroy does not revoke anything (`revoke_certificate_on_destroy = false`); the next apply
overwrites the files on the proxies.
