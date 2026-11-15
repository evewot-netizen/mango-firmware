#!/bin/sh
# Sourced only after validate_profile. No private key is emitted here.
render_network() {
cat <<BATCH
set network.wgverwaltung=interface
set network.wgverwaltung.proto=wireguard
set network.wgverwaltung.auto=1
set network.wgverwaltung.mtu=1420
set network.wgverwaltung.tunlink='$uplink'
add_list network.wgverwaltung.addresses='$client/32'
set network.wgverwaltung_pi=wireguard_wgverwaltung
set network.wgverwaltung_pi.public_key='$server_key'
set network.wgverwaltung_pi.endpoint_host='$endpoint'
set network.wgverwaltung_pi.endpoint_port='$port'
set network.wgverwaltung_pi.persistent_keepalive=25
set network.wgverwaltung_pi.route_allowed_ips=1
add_list network.wgverwaltung_pi.allowed_ips='$server/32'
BATCH
}
render_firewall() {
cat <<BATCH
set firewall.wgverwaltung=zone
set firewall.wgverwaltung.name=wgmgmt
add_list firewall.wgverwaltung.network=wgverwaltung
set firewall.wgverwaltung.input=DROP
set firewall.wgverwaltung.output=ACCEPT
set firewall.wgverwaltung.forward=DROP
set firewall.wgverwaltung.masq=0
set firewall.wgverwaltung_ssh=rule
set firewall.wgverwaltung_ssh.name='Pi SSH zum Mango'
set firewall.wgverwaltung_ssh.src=wgmgmt
set firewall.wgverwaltung_ssh.src_ip='$server'
set firewall.wgverwaltung_ssh.dest_ip='$client'
set firewall.wgverwaltung_ssh.proto=tcp
set firewall.wgverwaltung_ssh.dest_port=22
set firewall.wgverwaltung_ssh.family=ipv4
set firewall.wgverwaltung_ssh.target=ACCEPT
set firewall.wgverwaltung_ping=rule
set firewall.wgverwaltung_ping.name='Pi Ping zum Mango'
set firewall.wgverwaltung_ping.src=wgmgmt
set firewall.wgverwaltung_ping.src_ip='$server'
set firewall.wgverwaltung_ping.dest_ip='$client'
set firewall.wgverwaltung_ping.proto=icmp
add_list firewall.wgverwaltung_ping.icmp_type=echo-request
set firewall.wgverwaltung_ping.family=ipv4
set firewall.wgverwaltung_ping.target=ACCEPT
BATCH
for family in 4 6; do
    rule="mango_fritz_v$family"
    cat <<BATCH
set firewall.$rule=rule
set firewall.$rule.name='Mango-Fritz-v$family'
set firewall.$rule.dest='$zone'
set firewall.$rule.family='ipv$family'
set firewall.$rule.proto=tcp
set firewall.$rule.dest_port='80 443 49000 49443'
set firewall.$rule.target=REJECT
BATCH
    if test "$family" = 4; then addresses="$gateway 169.254.1.1"; else addresses=$gateways6; fi
    for address in $addresses; do
        printf "add_list firewall.%s.dest_ip='%s'\n" "$rule" "$address"
    done
done
}
