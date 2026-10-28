# Fabric spines

Configures RouterOS BGP, BFD, EVPN route reflection and IPv6 settings through
`modules/fabric/spines`. Inventory is `fabric.auto.tfvars`; provider aliases
select each spine's API. APIs must be reachable before applying. Set
`routeros_password` (and optionally `routeros_username`, default `admin`) in the
[secrets file](../../inventory/README.md#secrets).

```sh
tooling/walk-roots.sh fabric-spines
```

Leaves are the physical `fabric.leaves`, every cluster node and greatfox. Leaf IDs
determine default spine ports (`ether<ID>`); `spine_uplink` overrides the port
for physical leaves. Review plans against existing RouterOS configuration.
