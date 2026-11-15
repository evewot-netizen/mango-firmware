# Sequential daily fleet rollout

Configuration order is Mango Zuhause then Mango 02; later routers can be appended.
Home Assistant starts one round at 21:00 (HA local time; fleet day guard uses
Europe/Berlin). It fetches the channel offer once, persists its version/hash, and
processes one router at a time. Identical firmware is health-checked without
prepare, download or backup. Newer same-series test versions use the native
signed-manifest preparation, verified backup and hash-bound installation path.
Each updating router still fetches/verifies its signed manifest; this is required
verification, not a minute-by-minute discovery poll. A changed offer/hash stops
the rollout. Downgrades and release-series changes require manual review.

There is no idle minute trigger. Only an active automation waits one minute
between short controller invocations. A Home Assistant start resumes a persisted
round; it does not start a missed round or refetch the offer. A daily attempt is
recorded before the offer request, so a failure is not automatically retried.
Errors stop subsequent routers and remain blocked until an explicit recovery.
Router state files retain the original no-duplicate-install behavior. The fleet
lock serializes invocations. Interrupted uncertain starts fail closed.

The engine is a separate copy of the established controller with per-router
backup requirements and archive prefixes. The last three validated backups per
router are retained. Existing legacy controller and config are left on disk as
rollback material but HA shell commands all route to the fleet controller.
The automation retains its old unique ID and replaces the old 04:15 schedule.
No firmware update is initiated by the installer or by configuration verification.

Installer: requires exact known controller/package hashes and a quiet previous
state, checks expected Pi public keys, backs up old package/controller/config/state,
and writes only new fleet files and the existing update automation package.
It validates with ha core check and rolls back file changes on failure.
A subsequent HA Core restart loads changed shell commands and automation.
Private key/config backup to GD remains a separate task; no GD credentials are
embedded. Existing monitoring packages are not changed; any separate firmware
offer display sensor polling interval must be inspected independently.

Validation: 29 fleet/controller tests, Python compilation, YAML parsing, shell
syntax. Includes sequential progression, no-op current version, failure blocking,
one daily offer fetch, resume without refetch, interrupted start/offer, required
backup files, per-router naming, retention and pinned hash changes. Live HA
configuration check, Core execution verification and first daily round remain
required. A real future firmware flash cannot be proven by these mocked tests.
