# WireGuard boot recovery

Observed on Mango 02 test7: early endpoint DNS resolution failed, and netifd left
wgverwaltung unavailable with NO_DEVICE. Plain ifup did not recover it after DNS
became available. A protocol action 5 availability notification recovered the
interface with a fresh handshake.

The reconnect helper runs once per minute independently of gateway refresh. It
requires explicit enrollment, auto=1, matching tunlink, up=false, pending=false,
autostart=true and NO_DEVICE, plus an active uplink and a successful endpoint DNS
answer. It rechecks state immediately before notifying netifd. It does not issue
a second ifup, restart a healthy interface, pin a public IP or change firewall
rules. A directory lock prevents concurrent runs.

The guarded test7 installer targets only ffhal9483c41b9b72 / 172.27.66.3. It backs
up the cron and sysupgrade lists, rolls back on installer failure, and preserves
the helper and cron across sysupgrade. The source enrollment and upgrade hook
also schedule it for future images. No firmware build is needed for this backport.

Seven mocked state tests pass. The live availability notification was verified;
the installed scheduled helper still needs a reboot test and a test at the
father's connection. This does not address stale handshakes or all DDNS failures.
