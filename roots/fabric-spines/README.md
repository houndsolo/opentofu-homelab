# Fabric spines

Configures RouterOS BGP, BFD, EVPN route reflection and IPv6 settings through
`modules/fabric/spines`. Inventory is `fabric.auto.tfvars`; provider aliases
select each spine's API. APIs and credentials must be ready before applying.

```sh
tooling/walk-roots.sh fabric-spines
```

Leaf IDs determine default spine ports (`ether<ID>`); `spine_uplink` overrides
the port per leaf. Review plans against existing RouterOS configuration.
