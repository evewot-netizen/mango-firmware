#!/bin/sh
get() { uci -q get "mango_management.main.$1"; }
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
validate_profile() {
    endpoint=$(get endpoint_host) || fail 'endpoint_host fehlt.'
    hostname "$endpoint" || fail 'Ungueltiger Endpoint (IPv4 oder DNS-Name erforderlich).'
    server_key=$(get server_public_key) || fail 'Server-Public-Key fehlt.'
    printf '%s\n' "$server_key" | grep -Eq '^[A-Za-z0-9+/]{43}=$' || fail 'Ungueltiger Server-Public-Key.'
    client=$(get tunnel_address) || fail 'Tunneladresse fehlt.'
    server=$(get server_address) || fail 'Server-Tunneladresse fehlt.'
    ipv4 "$client" && ipv4 "$server" || fail 'Tunneladressen muessen IPv4 ohne CIDR sein.'
    test "$client" != "$server" || fail 'Client- und Serveradresse sind gleich.'
    gateway=$(get gateway_ipv4) || fail 'Gateway-Adresse fehlt.'
    ipv4 "$gateway" || fail 'Ungueltige Gateway-IPv4.'
    test "$gateway" != "$server" && test "$gateway" != "$client" || fail 'Gateway kollidiert mit Tunnel.'
    gateways6=$(get gateway_ipv6) || fail 'IPv6-Gatewayadressen fehlen (vorher ermitteln).'
    test -n "$gateways6" || fail 'IPv6-Gatewayadressen fehlen.'
    for address in $gateways6; do ipv6 "$address" || fail 'Ungueltige IPv6-Adresse.'; done
    zone=$(get uplink_zone) || fail 'Uplink-Zone fehlt.'
    case "$zone" in ''|*[!A-Za-z0-9_]*) fail 'Ungueltige Uplink-Zone.';; esac
    port=$(get endpoint_port) || fail 'Endpoint-Port fehlt.'
    case "$port" in ''|*[!0-9]*) fail 'Ungueltiger Port.';; esac
    test "$port" -ge 1 && test "$port" -le 65535 || fail 'Port ausserhalb 1..65535.'
    monitor_key=$(get monitor_public_key) || fail 'Monitoring-Public-Key fehlt.'
    printf '%s\n' "$monitor_key" | grep -Eq '^ssh-ed25519 [A-Za-z0-9+/]+={0,2}( [A-Za-z0-9_.@-]+)?$' || fail 'Nur ein einzelner Ed25519-Public-Key erlaubt.'
    test "$(printf '%s\n' "$monitor_key" | wc -l)" -eq 1 || fail 'Mehrzeiliger Public-Key.'
}
