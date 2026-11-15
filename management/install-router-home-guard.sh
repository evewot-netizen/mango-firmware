#!/bin/sh
set -eu
umask 077
test "$(cat /proc/sys/kernel/hostname)" = ffhale4956e45c3b1
test "$(cat /lib/gluon/release)" = 2025.1-halle1-mango-test7
test "$(uci -q get network.wgverwaltung.addresses)" = 172.27.66.2/32
test "$(uci -q get firewall.wgverwaltung.input)" = DROP
test "$(uci -q get firewall.wgverwaltung.forward)" = DROP
test -z "$(uci changes firewall)"
for tool in timeout jsonfilter iptables ip6tables; do command -v "$tool" >/dev/null; done
grep -Fxq /etc/mango-fritz-adressen.sh /etc/sysupgrade.conf
grep -Fq '/etc/mango-fritz-adressen.sh' /etc/crontabs/root
echo 'bcd9f6b8ae2e6358867e54f8435f66433bede0aa701a585e96b47dc4dd50b153  /etc/mango-fritz-adressen.sh' | sha256sum -c -

lock=/tmp/mango-fritz-adressen.lock
if ! mkdir "$lock" 2>/dev/null; then
    echo 'Adresspruefung gerade aktiv. Noch nichts geaendert; nach 20 Sekunden erneut versuchen.' >&2
    exit 1
fi
work=$(mktemp -d /tmp/mango-home-guard.XXXXXX)
changed=0
save=
cleanup() {
    result=$?
    trap - EXIT HUP INT TERM
    if test "$result" -ne 0 && test "$changed" = 1; then
        uci revert firewall || true
        cp -p "$save/firewall" /etc/config/firewall
        cp -p "$save/adressen.sh" /etc/mango-fritz-adressen.sh
        if /etc/init.d/firewall reload >/dev/null 2>&1; then
            echo 'FEHLER: Vorheriges Skript und Firewall wiederhergestellt.' >&2
        else
            echo 'FEHLER: Ruecknahme gespeichert, Firewall-Neuladen fehlgeschlagen.' >&2
        fi
    fi
    rm -rf "$work"
    rmdir "$lock" 2>/dev/null || true
    exit "$result"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
cat > "$work/adressen.sh" <<'MANGO_HOME_GUARD'
#!/bin/sh
set -eu
umask 077
fail() { echo "Mango management: $*" >&2; exit 1; }
ipv4() {
    printf '%s\n' "$1" | awk -F. '
        NF!=4 {exit 1}
        {for(i=1;i<=4;i++) if($i !~ /^[0-9]+$/ || length($i)>3 || $i+0>255) exit 1}
    '
}
# Reject shell/UCI metacharacters and malformed literals before any mutation.
ipv6() {
    printf '%s\n' "$1" | awk -F: '
        /[^0-9a-fA-F:]/ || !/:/ || /:::/ {exit 1}
        {s=$0; n=gsub(/::/,"",s); if(n>1) exit 1;
         for(i=1;i<=NF;i++) if(length($i)>4) exit 1;
         if(n==0) {if(NF!=8 || /^:/ || /:$/) exit 1}
         else {groups=0; for(i=1;i<=NF;i++) if(length($i)) groups++; if(groups>=8) exit 1}}
    '
}
hostname() {
    case "$1" in ''|*[!A-Za-z0-9.-]*|-*|.*|*..*|*-) return 1;; esac
    test "${#1}" -le 253
}
lock=/tmp/mango-fritz-adressen.lock
mkdir "$lock" 2>/dev/null || exit 0
trap 'rm -rf "$lock"' EXIT
trap 'exit 1' HUP INT TERM
error() { logger -t mango-fritz "$*"; fail "$*"; }
test -z "$(uci changes firewall)" || error 'Firewall-Aenderungen offen.'
uplink=wan
case "$uplink" in ''|*[!A-Za-z0-9_]*) error 'Ungueltiger Uplink.';; esac
zone=wan
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
name=fritz.box
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
    logger -t mango-fritz 'Uplink-Sperradressen ergaenzt.'
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
date +%s > /tmp/mango-fritz-last-check
MANGO_HOME_GUARD
sh -n "$work/adressen.sh"
save=$(mktemp -d /root/vor-mango-home-guard.XXXXXX)
cp -p /etc/config/firewall "$save/firewall"
cp -p /etc/mango-fritz-adressen.sh "$save/adressen.sh"
echo "Ruecknahme-Sicherung: $save"
changed=1
cp "$work/adressen.sh" /etc/mango-fritz-adressen.sh
chmod 700 /etc/mango-fritz-adressen.sh
# Keep the production lock held against cron/hotplug while checking the new logic.
sed "s|lock=/tmp/mango-fritz-adressen.lock|lock=$work/check-lock|" \
    /etc/mango-fritz-adressen.sh > "$work/check"
echo '--- Gateway- und DNS-Adresserkennung pruefen ---'
sh "$work/check"
echo '--- Aktive Sperren fuer alle Adressen und Ports pruefen ---'
for family in 4 6; do
    tool=iptables
    test "$family" = 4 || tool=ip6tables
    for address in $(uci -q get firewall.mango_fritz_v$family.dest_ip); do
        for port in 80 443 49000 49443; do
            "$tool" -C zone_wan_output -d "$address" -p tcp -m tcp --dport "$port" \
                -m comment --comment "!fw3: Mango-Fritz-v$family" -j zone_wan_dest_REJECT
        done
    done
done
echo '--- Verwaltung und Freifunk pruefen ---'
SSH_ORIGINAL_COMMAND=health /bin/sh /etc/mango-ha-update.sh
SSH_ORIGINAL_COMMAND=vpn /bin/sh /etc/mango-ha-monitor.sh
wg show wgverwaltung
echo 'ERFOLG: Schutz-Adresserkennung fuer Mango Zuhause aktualisiert.'
echo 'Kein Firmware-Flash und kein Netzwerk-Neustart ausgefuehrt.'
