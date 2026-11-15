#!/bin/sh
# Explicit recovery only, never called by a schedule. Lock matches HA Core.
set -eu
umask 077
command -v flock >/dev/null
command -v jq >/dev/null
state=/config/freifunk/update-status/mango-zuhause.json
config=/config/freifunk/mango-update-controller.json
exec 9>> /config/freifunk/update-status/mango-zuhause.lock
flock -n 9
jq -e '.installation_enabled == true and .state_file == "/config/freifunk/update-status/mango-zuhause.json"' "$config" >/dev/null
jq -e '(.phase == "INSTALLING" or .phase == "ERROR") and
    .old_boot == "89f96f09-fb52-4881-ae04-37a186065674" and
    .old_version == "2025.1-halle1-mango-test6" and
    .target_version == "2025.1-halle1-mango-test7" and
    .image_sha == "d71a081fe5b26d88f2a1fef2255dfd90199579fd95b9c9d86021a35375a55f4c"' "$state" >/dev/null
work=$(mktemp -d /config/freifunk/.recovery.XXXXXX)
trap 'rm -rf "$work"' EXIT
mango() {
    ssh -T -p 2222 -i /config/freifunk/ssh/mango_zuhause_update \
        -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10 \
        -o ServerAliveInterval=5 -o ServerAliveCountMax=2 \
        -o HostKeyAlias=192.168.178.20 -o HostKeyAlgorithms=ssh-ed25519 \
        -o StrictHostKeyChecking=yes \
        -o UserKnownHostsFile=/config/freifunk/ssh/known_hosts_mango \
        root@172.30.33.2 "$@" 9>&-
}
mango job > "$work/job"
awk '/^(STATE|VERSION|BOOT_ID|SHA256|INSTALL_ENABLED)=/ {print;next} {exit}' "$work/job" > "$work/header"
cat "$work/header"
grep -Fxq 'VERSION=2025.1-halle1-mango-test6' "$work/header"
grep -Fxq 'BOOT_ID=89f96f09-fb52-4881-ae04-37a186065674' "$work/header"
grep -Fxq 'INSTALL_ENABLED=1' "$work/header"
grep -Eq '^STATE=(QUEUED|PREPARING|READY)$' "$work/header"
if grep -Fxq 'STATE=READY' "$work/header"; then
    grep -Fxq 'SHA256=d71a081fe5b26d88f2a1fef2255dfd90199579fd95b9c9d86021a35375a55f4c' "$work/header"
fi
save=$(mktemp -d /config/freifunk/vor-update-wiederaufnahme.XXXXXX)
cp -p "$state" "$save/state.json"
echo "Bisheriger Pi-Zustand gesichert: $save/state.json"
# A new run must create a new backup; do not carry over the previous receipt.
jq -n --argjson started "$(date +%s)" '{phase:"CHECKING",started:$started}' > "$work/state.json"
chmod 600 "$work/state.json"
mv "$work/state.json" "$state"
echo 'ERFOLG: Pi-Steuerung auf CHECKING gesetzt.'
echo 'Die aktive Automation uebernimmt: Pruefung, frisches Backup, Installation, Funktionspruefung.'
