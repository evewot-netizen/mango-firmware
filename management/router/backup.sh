#!/bin/sh
set -eu
umask 077
test "${SSH_ORIGINAL_COMMAND:-}" = backup || exit 1
exec 9> /var/lock/mango-ha-backup.lock
flock -n 9 || exit 1
work=$(mktemp -d /tmp/mango-ha-backup.XXXXXX)
trap 'rm -rf "$work"' EXIT
trap 'exit 1' HUP INT TERM
sysupgrade -b "$work/config.tar.gz" 9>&- >&2
tar -tzf "$work/config.tar.gz" >/dev/null
cat "$work/config.tar.gz"
