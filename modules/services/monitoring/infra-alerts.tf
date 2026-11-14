# Alert rules for the network, the hosts and their hardware (DT-007): before these only TargetDown, ProbeFailed
# and FilesystemAlmostFull covered them, so a bgpd crash, a 53-min BFD outage on fw-wan, a down IPsec tunnel and
# a failed PSU went unalerted. Every metric and label used here was checked against the live Prometheus.
#
# greatfox (and leaf-20 on it) is often powered off on purpose: its series simply disappear, so no rule here
# uses absent() or compares "now" with a time before the gap (offset/increase see no series and stay quiet).
# TargetDown is the only alert that sees it off. The Loki-side rules (RouterOS BGP lines, kernel disk and
# hardware errors) are in logging.tf (loki_rules_yml).
locals {
  # The fabric and vpn groups only with VyOS targets (a for-filter: the two groups differ in shape, so a
  # conditional "? [] : [...]" can't unify them).
  infra_rules = concat([for g in [
    {
      name = "fabric"
      rules = [
        # FRR on VyOS logs %ADJCHANGE/BFD changes at informational and VyOS forces "log syslog
        # notifications", so the session state comes from frr_exporter (job vyos-frr), not from the logs.
        {
          alert       = "BGPSessionDown"
          expr        = "frr_bgp_peer_state{job=\"vyos-frr\"} != 1"
          for         = "2m"
          labels      = { severity = "critical" }
          annotations = { summary = "{{ $labels.host }}: BGP peer {{ $labels.peer }} ({{ $labels.peer_hostname }}, vrf {{ $labels.vrf }}, {{ $labels.afi }}/{{ $labels.safi }}) is not Established" }
        },
        # The 2026-11-09 bgpd crash was a single-scrape dip (sessions back in < 30 s): only the uptime reset shows it.
        {
          alert       = "BGPSessionReset"
          expr        = "sum by (host) (resets(frr_bgp_peer_uptime_seconds{job=\"vyos-frr\"}[5m])) > 0"
          labels      = { severity = "warning" }
          annotations = { summary = "{{ $labels.host }}: {{ $value }} BGP session(s) re-established in the last 5m (flap, peer reboot or bgpd restart)" }
        },
        {
          alert       = "BFDPeerDown"
          expr        = "frr_bfd_peer_state{job=\"vyos-frr\"} != 1"
          for         = "1m"
          labels      = { severity = "critical" }
          annotations = { summary = "{{ $labels.host }}: BFD peer {{ $labels.peer }} (local {{ $labels.local }}) is down" }
        },
        # A peer that vanishes from the export (unconfigured, VRF gone, bgpd lost the instance) isn't "down".
        # A whole router going away (greatfox off) has no left-hand side, so it doesn't fire.
        {
          alert       = "BGPPeerCountDropped"
          expr        = "count by (host) (frr_bgp_peer_state{job=\"vyos-frr\"}) < count by (host) (frr_bgp_peer_state{job=\"vyos-frr\"} offset 1h)"
          for         = "10m"
          labels      = { severity = "warning" }
          annotations = { summary = "{{ $labels.host }} exports {{ $value }} BGP peers, fewer than an hour ago (a peer was removed or disappeared)" }
        },
        # A failing collector hides the rules above for that router (no series = no alert).
        {
          alert       = "FRRCollectorFailing"
          expr        = "frr_collector_up{job=\"vyos-frr\"} == 0"
          for         = "15m"
          labels      = { severity = "warning" }
          annotations = { summary = "{{ $labels.host }}: frr_exporter collector {{ $labels.collector }} fails (its BGP/BFD alerts are blind)" }
        },
      ]
    },
    {
      name = "vpn"
      rules = [
        # vpn-metrics.py on fw-wan (roots/monitoring-config/vyos/), node_exporter textfile, job vyos-node.
        # WireGuard peers are road warriors (down when not connected): only the collector is alerted on.
        {
          alert       = "IPsecTunnelDown"
          expr        = "vyos_ipsec_ike_up{job=\"vyos-node\"} == 0"
          for         = "15m"
          labels      = { severity = "critical" }
          annotations = { summary = "{{ $labels.host }}: IPsec IKE SA {{ $labels.connection }} to {{ $labels.remote }} is down" }
        },
        {
          alert       = "IPsecChildSADown"
          expr        = "vyos_ipsec_child_up{job=\"vyos-node\"} == 0 and on (host, connection) vyos_ipsec_ike_up{job=\"vyos-node\"} == 1"
          for         = "15m"
          labels      = { severity = "warning" }
          annotations = { summary = "{{ $labels.host }}: IPsec {{ $labels.connection }} is up but its child SA {{ $labels.child }} is not" }
        },
        {
          alert       = "VPNMetricsFailing"
          expr        = "vyos_vpn_metrics_ipsec_ok{job=\"vyos-node\"} == 0 or vyos_vpn_metrics_wireguard_ok{job=\"vyos-node\"} == 0 or time() - vyos_vpn_metrics_last_run_timestamp_seconds{job=\"vyos-node\"} > 900"
          for         = "15m"
          labels      = { severity = "warning" }
          annotations = { summary = "{{ $labels.host }}: vpn-metrics.py fails or stopped running (the IPsec alerts are blind)" }
        },
      ]
    },
    ] : g if length(var.targets.vyos) > 0], [
    {
      name = "hosts"
      rules = [
        # node_boot_time_seconds moved forward since 30 min ago (> 60 s: ignores btime jitter). Fires for 30 min after
        # each reboot. A host that was off for longer (greatfox) has no series 30 min back and doesn't fire.
        {
          alert       = "NodeRebooted"
          expr        = "node_boot_time_seconds{job=~\"node|vyos-node\"} - (node_boot_time_seconds{job=~\"node|vyos-node\"} offset 30m) > 60"
          labels      = { severity = "info" }
          annotations = { summary = "{{ $labels.host }} rebooted in the last 30 minutes" }
        },
        # Podman healthcheck runs are transient units (<64-hex container id>-<hex>.service) that stay failed after a
        # container restart until reset-failed; the containers' own alerts cover their health.
        {
          alert       = "SystemdUnitFailed"
          expr        = "node_systemd_unit_state{job=\"node\", state=\"failed\", name!~\"[0-9a-f]{64}-[0-9a-f]+[.]service\"} == 1"
          for         = "15m"
          labels      = { severity = "warning" }
          annotations = { summary = "{{ $labels.host }}: systemd unit {{ $labels.name }} has failed (systemctl status {{ $labels.name }})" }
        },
      ]
    },
    {
      name = "hardware"
      rules = [
        # smartmon textfile collector on the PVE nodes. Several disks already carry old, flat counts (macbeth sdf:
        # 896 reallocated, 16 pending; fichina sdb 218): alert on growth so they don't fire forever. Reallocated and
        # reported-uncorrectable are lifetime counters (increase); pending/offline-uncorrectable go down again when
        # sectors are remapped, so they're compared with delta (a drop is no alert, and no false "reset").
        {
          alert       = "SmartReallocatedSectorsGrowing"
          expr        = "increase(smartmon_reallocated_sector_ct_raw_value{job=\"node\"}[1d]) > 0"
          labels      = { severity = "warning" }
          annotations = { summary = "{{ $labels.host }} {{ $labels.disk }}: {{ $value | humanize }} more reallocated sectors in 24h (failing disk; run a long SMART test)" }
        },
        {
          alert       = "SmartUncorrectableErrorsGrowing"
          expr        = "increase(smartmon_reported_uncorrect_raw_value{job=\"node\"}[1d]) > 0"
          labels      = { severity = "warning" }
          annotations = { summary = "{{ $labels.host }} {{ $labels.disk }}: {{ $value | humanize }} new uncorrectable read errors reported in 24h" }
        },
        {
          alert       = "SmartPendingSectorsGrowing"
          expr        = "delta(smartmon_current_pending_sector_raw_value{job=\"node\"}[1d]) > 0 or delta(smartmon_offline_uncorrectable_raw_value{job=\"node\"}[1d]) > 0"
          labels      = { severity = "warning" }
          annotations = { summary = "{{ $labels.host }} {{ $labels.disk }}: SMART attribute {{ $labels.smart_id }} (pending/offline-uncorrectable sectors) grew by {{ $value | humanize }} in 24h" }
        },
        {
          alert       = "SmartDiskUnhealthy"
          expr        = "smartmon_device_smart_healthy{job=\"node\"} == 0"
          for         = "15m"
          labels      = { severity = "critical" }
          annotations = { summary = "{{ $labels.host }} {{ $labels.disk }}: SMART overall health self-assessment FAILED" }
        },
        # MikroTik PSUs (mikrotik_lite: mtxrHlPowerSupplyState/mtxrHlBackupPowerSupplyState, 1 = ok; only the
        # CRS317s answer). The backup PSU reads "fail" on both CRS317s (psu2 not powered), so it only alerts when it
        # was ok within the last day and isn't now.
        {
          alert       = "MikroTikPSUFailed"
          expr        = "mtxrHlPowerSupplyState{job=~\"snmp-.*\"} == 0"
          for         = "5m"
          labels      = { severity = "critical" }
          annotations = { summary = "{{ $labels.host }}: primary power supply reports fail (/system health)" }
        },
        {
          alert       = "MikroTikBackupPSULost"
          expr        = "mtxrHlBackupPowerSupplyState{job=~\"snmp-.*\"} == 0 and max_over_time(mtxrHlBackupPowerSupplyState{job=~\"snmp-.*\"}[1d]) == 1"
          for         = "5m"
          labels      = { severity = "warning" }
          annotations = { summary = "{{ $labels.host }}: backup power supply went from ok to fail (no PSU redundancy; clears after a day)" }
        },
      ]
    },
  ])
}
