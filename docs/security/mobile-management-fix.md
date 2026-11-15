# Management fixes for changing uplinks and Gluon upgrades

The enrolled Mango 02 on test7 can receive `management/install-router-mobile-fix.sh`
without reflashing. The installer verifies its hostname, firmware, tunnel address,
and original refresh-script hash. It preserves the existing network and keys.
Before running it, create a fresh sysupgrade backup in private Google Drive, including
the newly enrolled profile and management key. The PowerShell wrapper must verify
the installer and backup hashes before execution. No secrets are in this repository.

Changes:
- Resolve the actual private uplink device via ifstatus and take default gateways
  only from that device. Never use the Freifunk client's fallback route.
- Add its IPv4 gateway and IPv6 default-router addresses before querying DNS.
- Query fritz.box at the current gateway and retain old IPv4/IPv6 addresses.
- DNS failures leave directly discovered gateway guards in place, report failure,
  and do not produce a new successful-check timestamp.
- Preserve the existing TCP-only output guards for ports 80, 443, 49000, 49443;
  this is not a general forwarded-client isolation or all-ports LAN block.
- Add a 997 upgrade hook to restore missing WireGuard network sections from the
  enrolled profile and existing private key before Gluon's 998-commit.
  Refuse partial or conflicting existing sections instead of overwriting them.
- Preserve the local backport scripts explicitly through sysupgrade.conf.

Validation: five behavioral tests for site changes, DNS failure, modified rules,
network reset and conflicting sections, plus the existing thirteen security tests.
The installer additionally checks the concrete active iptables/ip6tables rule for
EVERY saved address and protected port, and checks that its idempotent restoration
probe did not modify /etc/config/network. Tests use mocked OpenWrt commands; a real
reboot and a test at the father's Internet connection are still required.

Limits: discovery runs on interface events and once per minute. This does not
promise zero exposure time during a site transition, DNS outage, or firewall reload.
If no unique IPv4 uplink gateway is available the previous guards remain and the
check fails. Each family is bounded to 64 saved addresses; exceeding this requires
review. A stale MyFRITZ resolution/reconnection needs separate operational testing.
The firmware alone does not install the Pi's backup/update controller.

Deployment branch: mango-dev-update-control. No firmware build is triggered by this
branch. Build a future version from the corrected sources to distribute the fixes
inside new images; do not silently replace the published signed test7 binary.
