#!/bin/sh
# Backport for the enrolled Mango 02 on test7. Does not flash or restart networking.
set -eu
umask 077
test "$(cat /proc/sys/kernel/hostname)" = ffhal9483c41b9b72
test "$(cat /lib/gluon/release)" = 2025.1-halle1-mango-test7
test "$(uci -q get mango_management.main.enabled)" = 1
test "$(uci -q get network.wgverwaltung.addresses)" = 172.27.66.3/32
test "$(uci -q get network.wgverwaltung.tunlink)" = wan
test "$(uci -q get firewall.wgverwaltung.input)" = DROP
test "$(uci -q get firewall.wgverwaltung.forward)" = DROP
test ! -e /usr/sbin/mango-management-restore
test ! -e /lib/gluon/upgrade/997-mango-management-network
test -f /etc/sysupgrade.conf
for config in network firewall mango_management; do
    test -z "$(uci changes "$config")"
done
command -v timeout >/dev/null
command -v jsonfilter >/dev/null
command -v iptables >/dev/null
command -v ip6tables >/dev/null
echo '49239dc9947c24f04b6e3a32edf9b6040d52fca11915ed2cf6f8c2df46f70b8d  /usr/sbin/mango-management-refresh' | sha256sum -c -
# Use the same lock as cron/hotplug while replacing scripts.
lock=/tmp/mango-management-refresh.lock
if ! mkdir "$lock" 2>/dev/null; then
    echo 'Adresspruefung gerade aktiv. Noch nichts geaendert; nach 20 Sekunden erneut ausfuehren.' >&2
    exit 1
fi
work=$(mktemp -d /tmp/mango-mobile-fix.XXXXXX)
installed=0
save=
cleanup() {
    result=$?
    trap - EXIT HUP INT TERM
    if test "$result" -ne 0 && test "$installed" = 1; then
        uci revert firewall || true
        cp -p "$save/firewall" /etc/config/firewall
        cp -p "$save/refresh" /usr/sbin/mango-management-refresh
        cp -p "$save/sysupgrade.conf" /etc/sysupgrade.conf
        rm -f /usr/sbin/mango-management-restore /lib/gluon/upgrade/997-mango-management-network
        /etc/init.d/firewall reload >/dev/null 2>&1 || true
        echo 'FEHLER: Vorherige Skripte und Firewall wiederhergestellt.' >&2
    fi
    rm -rf "$work"
    rmdir "$lock" 2>/dev/null || true
    exit "$result"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
cat > "$work/file0" <<'MANGO_FILE_0'
#!/bin/sh
set -eu
umask 077
. /usr/lib/mango-management/common.sh
test "$(get enabled || true)" = 1 || exit 0
lock=/tmp/mango-management-refresh.lock
mkdir "$lock" 2>/dev/null || exit 0
trap 'rm -rf "$lock"' EXIT
trap 'exit 1' HUP INT TERM
error() { logger -t mango-management "$*"; fail "$*"; }
test -z "$(uci changes firewall)" || error 'Firewall-Aenderungen offen.'
uplink=$(get uplink_interface)
case "$uplink" in ''|*[!A-Za-z0-9_]*) error 'Ungueltiger Uplink.';; esac
zone=$(get uplink_zone)
case "$zone" in ''|*[!A-Za-z0-9_]*) error 'Ungueltige Zone.';; esac
for family in 4 6; do
    rule=firewall.mango_fritz_v$family
    test "$(uci -q get "$rule.target")" = REJECT || error 'Sperrregel veraendert.'
    test "$(uci -q get "$rule.dest")" = "$zone" || error 'Sperrzone veraendert.'
    test "$(uci -q get "$rule.proto")" = tcp || error 'Sperrprotokoll veraendert.'
    test "$(uci -q get "$rule.dest_port")" = '80 443 49000 49443' || error 'Sperrports veraendert.'
done
# Select the private uplink device, never a Freifunk default route.
ifstatus "$uplink" > "$lock/status" || error 'Uplink nicht verfuegbar.'
test "$(jsonfilter -i "$lock/status" -e '@.up')" = true || error 'Uplink ist nicht aktiv.'
device=$(jsonfilter -i "$lock/status" -e '@.l3_device')
case "$device" in ''|*[!A-Za-z0-9_.:-]*) error 'Ungueltiges Uplink-Geraet.';; esac
ip -4 route show default dev "$device" > "$lock/routes4"
awk '$1=="default" && $2=="via" {print $3}' "$lock/routes4" | sort -u > "$lock/gateways4"
test "$(wc -l < "$lock/gateways4")" -eq 1 || error 'Kein eindeutiges IPv4-Uplink-Gateway.'
gateway=$(cat "$lock/gateways4")
ipv4 "$gateway" || error 'Ungueltiges IPv4-Gateway.'
ip -6 route show default dev "$device" > "$lock/routes6"
awk '$1=="default" && $2=="via" {print tolower($3)}' "$lock/routes6" | sort -u > "$lock/gateways6"
name=$(get gateway_dns_name)
hostname "$name" || error 'Ungueltiger Gateway-DNS-Name.'
old4=$(uci -q get firewall.mango_fritz_v4.dest_ip)
old6=$(uci -q get firewall.mango_fritz_v6.dest_ip)
new4=$old4
new6=$old6
add4() {
    ipv4 "$1" || error 'Ungueltige IPv4-Adresse.'
    case " $new4 " in *" $1 "*) ;; *) new4="$new4 $1";; esac
}
add6() {
    ipv6 "$1" || error 'Ungueltige IPv6-Adresse.'
    case " $new6 " in *" $1 "*) ;; *) new6="$new6 $1";; esac
}
add4 "$gateway"
add4 169.254.1.1
while IFS= read -r address; do add6 "$address"; done < "$lock/gateways6"
# Publish directly observed gateways even if DNS is unavailable. Keep old addresses.
apply_lists() {
    test "$(printf '%s\n' "$new4" | awk '{print NF}')" -le 64 || error 'IPv4-Liste voll.'
    test "$(printf '%s\n' "$new6" | awk '{print NF}')" -le 64 || error 'IPv6-Liste voll.'
    if test "$new4" = "$old4" && test "$new6" = "$old6"; then return; fi
    cp -p /etc/config/firewall "$lock/firewall"
    if ! (
        set -e
        for address in $new4; do
            case " $old4 " in *" $address "*) ;; *) uci add_list "firewall.mango_fritz_v4.dest_ip=$address" || exit 1;; esac
        done
        for address in $new6; do
            case " $old6 " in *" $address "*) ;; *) uci add_list "firewall.mango_fritz_v6.dest_ip=$address" || exit 1;; esac
        done
        uci commit firewall || exit 1
        /etc/init.d/firewall reload > "$lock/reload" 2>&1
    ); then
        uci revert firewall || true
        cp -p "$lock/firewall" /etc/config/firewall
        /etc/init.d/firewall reload >/dev/null 2>&1 || true
        error 'Firewall-Aktualisierung fehlgeschlagen; vorherige Regeln wiederhergestellt.'
    fi
    old4=$new4
    old6=$new6
    logger -t mango-management 'Uplink-Sperradressen ergaenzt.'
}
apply_lists
# Query the CURRENT private gateway, not the previous site's saved IPv4 address.
timeout 15 nslookup "$name" "$gateway" > "$lock/dns" 2>&1 || error 'DNS fehlgeschlagen; Gateway-Sperren aktiv, alte DNS-Adressen erhalten.'
awk '/^Name:/ {answer=1; next} answer && /^Address([[:space:]]|:)/ {print $NF}' "$lock/dns" | sort -u > "$lock/answers"
test -s "$lock/answers" || error 'Keine Gateway-DNS-Antworten.'
while IFS= read -r address; do
    case "$address" in
        *:*) address=$(printf '%s' "$address" | tr A-F a-f); add6 "$address";;
        *) add4 "$address";;
    esac
done < "$lock/answers"
apply_lists
date +%s > /tmp/mango-management-last-check
MANGO_FILE_0
sh -n "$work/file0"
cat > "$work/file1" <<'MANGO_FILE_1'
#!/bin/sh
# Recreate only missing management network sections after Gluon's UCI reset.
set -eu
umask 077
. /usr/lib/mango-management/common.sh
. /usr/lib/mango-management/render.sh
test "$(get enabled || true)" = 1 || exit 0
validate_profile
test -s /etc/wireguard/mango-management.key || fail 'WireGuard-Schluessel fehlt.'
wg pubkey < /etc/wireguard/mango-management.key >/dev/null || fail 'WireGuard-Schluessel ungueltig.'
test "$(uci -q get firewall.wgverwaltung.name)" = wgmgmt || fail 'Verwaltungszone fehlt.'
test "$(uci -q get firewall.wgverwaltung.input)" = DROP || fail 'Input-Schutz fehlt.'
test "$(uci -q get firewall.wgverwaltung.forward)" = DROP || fail 'Forward-Schutz fehlt.'
test "$(uci -q get firewall.wgverwaltung.network)" = wgverwaltung || fail 'Zonenzuordnung abweichend.'
if uci -q get network.wgverwaltung >/dev/null || uci -q get network.wgverwaltung_pi >/dev/null; then
    test "$(uci -q get network.wgverwaltung.proto)" = wireguard || fail 'Bestehende Schnittstelle weicht ab.'
    test "$(uci -q get network.wgverwaltung.addresses)" = "$client/32" || fail 'Bestehende Tunneladresse weicht ab.'
    test "$(uci -q get network.wgverwaltung.tunlink)" = "$uplink" || fail 'Bestehender Uplink weicht ab.'
    test "$(uci -q get network.wgverwaltung_pi.public_key)" = "$server_key" || fail 'Bestehender Peer weicht ab.'
    test "$(uci -q get network.wgverwaltung_pi.allowed_ips)" = "$server/32" || fail 'Bestehende Peer-Adressen weichen ab.'
    test "$(uci -q get network.wgverwaltung.private_key)" = "$(cat /etc/wireguard/mango-management.key)" || fail 'Bestehender Schluessel weicht ab.'
    echo 'Verwaltungstunnel bereits passend konfiguriert.'
    exit 0
fi
# During Gluon upgrade other network changes are pending. Do not revert or commit
# them here; 998-commit owns the transaction after this 997 hook.
render_network | uci batch
uci set network.wgverwaltung.private_key="$(cat /etc/wireguard/mango-management.key)"
echo 'Verwaltungsnetz wiederhergestellt; Gluon uebernimmt den Commit.'
MANGO_FILE_1
sh -n "$work/file1"
cat > "$work/file2" <<'MANGO_FILE_2'
#!/bin/sh
exec /usr/sbin/mango-management-restore
MANGO_FILE_2
sh -n "$work/file2"
save=$(mktemp -d /root/vor-mango-mobile-fix.XXXXXX)
cp -p /etc/config/firewall "$save/firewall"
cp -p /etc/sysupgrade.conf "$save/sysupgrade.conf"
cp -p /usr/sbin/mango-management-refresh "$save/refresh"
echo "Lokale Ruecknahme-Sicherung: $save"
installed=1
cp "$work/file0" /usr/sbin/mango-management-refresh
chmod 700 /usr/sbin/mango-management-refresh
grep -Fxq '/usr/sbin/mango-management-refresh' /etc/sysupgrade.conf || printf '%s\n' '/usr/sbin/mango-management-refresh' >> /etc/sysupgrade.conf
cp "$work/file1" /usr/sbin/mango-management-restore
chmod 700 /usr/sbin/mango-management-restore
grep -Fxq '/usr/sbin/mango-management-restore' /etc/sysupgrade.conf || printf '%s\n' '/usr/sbin/mango-management-restore' >> /etc/sysupgrade.conf
cp "$work/file2" /lib/gluon/upgrade/997-mango-management-network
chmod 700 /lib/gluon/upgrade/997-mango-management-network
grep -Fxq '/lib/gluon/upgrade/997-mango-management-network' /etc/sysupgrade.conf || printf '%s\n' '/lib/gluon/upgrade/997-mango-management-network' >> /etc/sysupgrade.conf
echo '--- Upgrade-Wiederherstellung auf vorhandener Konfiguration pruefen ---'
network_before=$(sha256sum /etc/config/network)
/usr/sbin/mango-management-restore
test "$network_before" = "$(sha256sum /etc/config/network)"
# Keep the production lock while running the same refresh logic with a private
# lock directory for this one installer invocation. Cron remains excluded.
sed "s|lock=/tmp/mango-management-refresh.lock|lock=$work/refresh-lock|" \
    /usr/sbin/mango-management-refresh > "$work/refresh-test"
echo '--- Aktuelle Gateway-Adressen und DNS pruefen ---'
sh "$work/refresh-test"
echo '--- Alle konfigurierten Sperradressen und Ports in der Firewall pruefen ---'
zone=$(uci -q get mango_management.main.uplink_zone)
for family in 4 6; do
    tool=iptables
    test "$family" = 4 || tool=ip6tables
    for address in $(uci -q get firewall.mango_fritz_v$family.dest_ip); do
        for port in 80 443 49000 49443; do
            "$tool" -C "zone_${zone}_output" -d "$address" -p tcp -m tcp --dport "$port" \
                -m comment --comment "!fw3: Mango-Fritz-v$family" -j "zone_${zone}_dest_REJECT"
        done
    done
done
wg show wgverwaltung
ip -4 route get 172.27.66.1
echo 'ERFOLG: Standort-Adresserkennung und Upgrade-Wiederherstellung korrigiert.'
echo 'Kein Firmware-Flash und kein Netzwerk-Neustart ausgefuehrt.'
echo 'Neustarttest und Test am Anschluss des Vaters stehen noch aus.'
