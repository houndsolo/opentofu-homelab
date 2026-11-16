#!/bin/sh
# Managed by Ansible (proxmox-lylat/tasks/no-subscription-nag.yml).
# Removes the "No valid subscription" popup from the PVE web UI. Runs from the
# apt hook /etc/apt/apt.conf.d/86pve-no-nag after every dpkg run, because each
# proxmox-widget-toolkit upgrade restores the original proxmoxlib.js.
#
# Inside Proxmox.Utils.checked_command() the popup is replaced with a direct
# orig_cmd() call, so the wrapped buttons (Updates > Refresh, Repositories > Add,
# System Report, Package versions) still run their action.
# Prints "patched" when it changed the file. Safe to run any number of times.
f=/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
[ -f "$f" ] || exit 0
re='(?:Ext\.Msg\.show|(?<!orig_cmd\(\); )void)\(\{(\s*title: gettext\(.No valid subscription.\))'
if RE="$re" perl -0ne 'exit(/$ENV{RE}/ ? 0 : 1)' "$f"; then
    RE="$re" perl -0pi -e 's/$ENV{RE}/orig_cmd(); void({$1/' "$f"
    echo patched
fi
