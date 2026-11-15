# Mango 02 restricted update access

This installer adds separate forced-command SSH keys for backup and update
control on ffhal9483c41b9b72 / test7 / 172.27.66.3. It retains existing admin and
monitor keys. No unrestricted shell or forwarding is granted to the new keys.
The backup command streams a temporary sysupgrade configuration archive, keeps
diagnostics on stderr, and rejects other commands. The update dispatcher uses
the existing tested preparation/install workers including lock descriptor
closure and the known network-stop hook fix. Its health check uses the mobile
management refresh path rather than the legacy home-router script.

The installer verifies router identity, update channel, the known network hook,
and absence of prior update scripts. It backs up authorized_keys/sysupgrade.conf,
rolls back additions on failure, preserves the files across upgrade, checks
health and creates a test archive. It does not prepare/download/flash firmware,
start a worker or enable it at boot. Existing native autoupdater stays disabled.
The Pi fleet schedule must be configured and activated separately after testing
the restricted SSH accesses and backup from the Pi.

Validation: shell syntax; 15 existing install tests and 13 preparation tests;
backup command test for restricted input, valid archive stdout, stderr separation.
Live installer and Pi access tests are pending.
