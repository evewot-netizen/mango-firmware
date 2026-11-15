# Controlled Mango update preparation

This is the preparation stage for Pi-controlled updates, not an enabled firmware rollout.
The existing backup is run only when a new firmware is available. The intended
nightly check is 04:15 in Home Assistant's configured local timezone; no scheduler
is installed by this directory yet. Retain three successful backups.

`install-router-prepare.sh` replaces the already tested procd selftest worker,
backs up the existing scripts, and installs a forced-command dispatcher. It does
not change SSH keys, start a download, enable a boot service, or install firmware.
It adds the scripts to sysupgrade.conf so a subsequent configuration backup retains them.

Commands accepted by the update key:

- `status`: existing release/channel settings.
- `check`: the earlier synchronous dry-run, retained for compatibility.
- `prepare`: queue a procd-owned dry-run, independent of the SSH connection.
- `job`: report IDLE, QUEUED, PREPARING, NO_UPDATE, READY or ERROR and recent logs.

The native autoupdater validates the signed manifest, version, hardware and image
hash. A successful downloaded image is moved to a private temporary directory;
its SHA256 and previous installed version are recorded. Existing READY work is
retained. Missing/ambiguous output, invalid settings and pre-existing manual
/tmp/firmware.bin fail closed. The worker never calls sysupgrade to flash; all
installation commands are rejected.

This implementation is matched to freifunk-gluon/packages commit
`d75722c2ee89dcca228b02465bdd8107c574676d`. Changes in updater messages must be
reviewed before updating the parser. The native download/abort hooks can briefly
stop and restart ancillary services when new firmware is downloaded. No hooks
are run when no new version is available.

Still required before rollout: backup receipt and exact candidate binding,
installation worker with upgrade hooks, bounded job polling, post-reboot checks,
notifications, sequential router handling and activation of the HA schedule.
No unattended installation or automatic recovery/rollback is claimed.

Tests: `python3 -m unittest discover -s management/tests -v`.
Mocks cover failures and command restrictions; they do not validate a real flash.
