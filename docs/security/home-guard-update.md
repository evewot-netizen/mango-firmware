# Mango Zuhause gateway guard update

Live review on 2026-11-15 confirmed all configured IPv4 and IPv6 TCP guard rules
were active for the currently observed FRITZ!Box addresses. WireGuard was healthy.
The legacy refresh script only queried AAAA records at a hard-coded IPv4 DNS
server, with no explicit timeout, no detection of changed IPv4/link-local gateways,
and no rollback after a reload failure.

The standalone legacy replacement uses the tested mobile gateway refresh logic,
with fixed wan uplink/zone and fritz.box name, retaining the original script path,
cron and hotplug callers. It requires no mango_management profile and does not
alter the WireGuard, monitoring or update configuration. The installer verifies
the old script hash and router identity, locks out concurrent refreshes, backs up
the old script/firewall, and checks every configured address/port in the active
iptables rules. Failed installation restores the previous script/configuration.

Existing addresses are retained. Detection uses only the private uplink device;
Freifunk default routes are excluded. Directly observed gateways are added even
when DNS is unavailable. DNS queries have a 15-second deadline. No writes/reloads
occur when addresses are unchanged. Lists are capped at 64 entries per family;
reaching that cap requires maintenance, old entries are not automatically deleted.

Scope remains router-originated TCP to ports 80, 443, 49000, 49443 on the detected
router addresses. This is not a blanket block of all LAN traffic or proof of total
network isolation. Cron and interface events detect changes with a delay.

Validation: shell syntax; mocked tests for gateway changes, link-local/DNS address
addition, existing-address retention, idempotence, DNS failure, modified-rule
refusal, and operation without a management enrollment profile. Live installation
and post-installation checks are pending user execution.
