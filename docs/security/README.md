# Mango-Sicherheitsvorlage – Test7, noch nicht auf Hardware freigegeben

Diese Vorlage verpackt die Grundstruktur der am ersten Mango manuell getesteten
Einrichtung. Sie ist eine neue Implementierung: Die Tests des bisherigen Routers
ersetzen weder den Firmware-Build noch den Gerätetest dieses Pakets.

## Verhalten

- Das Paket ist enthalten, das Standortprofil zunächst **deaktiviert**.
- Kein automatischer Verbindungsaufbau mit fremden oder vorgegebenen Schlüsseln.
- Keine privaten Schlüssel, Heimnetz-Adressen oder persönlichen DNS-Namen im Image.
- `mango-management-keygen` erzeugt einmalig einen privaten Schlüssel direkt am
  Router. Ein vorhandener Schlüssel wird weder ersetzt noch ausgegeben.
- `mango-management-enroll --check` prüft das lokale Profil syntaktisch.
- `mango-management-enroll --apply` ist eine ausdrückliche, lokale Erstaufnahme.
  Vorhandene wgverwaltung-/Sperrregeln werden nicht überschrieben. Test6-Router
  benötigen eine gesonderte Migration; diesen Installer dort nicht anwenden.
- Tunnelroute nur zur Pi-Tunneladresse /32. Zone wgmgmt: INPUT/FORWARD DROP,
  SSH/ICMP ausschließlich von der Pi-Tunneladresse. Keine LAN-Weiterleitung/NAT.
- SSH-Monitoring-Key nur mit Forced Command; keine Shell, Port-, Agent-, X11-
  Weiterleitung oder PTY. Zulässig sind leer (Firmware/Laufzeit), vpn, details.
- Gateway-Sperren sind lokale OUTPUT-Regeln für TCP 80, 443, 49000, 49443,
  keine pauschale Sperre des Internet-Gateways oder seiner DNS-Dienste.
- Minütliche DNS-Abfrage am expliziten Gateway sowie WAN-Hotplug. Bei DNS-Fehler
  oder offenen UCI-Änderungen bleiben die Regeln erhalten. Neue IPv6-Adressen
  werden ergänzt. Alte bleiben zum Schutz paralleler Präfixe enthalten.
- Maximal 64 IPv6-Adressen: danach protokollierter Wartungsbedarf statt
  unbegrenztem Wachstum. Alte Präfixe erst nach Prüfung manuell entfernen.
- Ein erfolgreicher Refresh hinterlegt `/tmp/mango-management-last-check`.
  Gleichbleibende Adressen erzeugen keine Konfigurations-/Flash-Schreibzugriffe.
- Schlüssel/Profil/Cron/SSH-Konfiguration werden für sysupgrade vorgemerkt.
  Ein Gluon-Upgrade-Hook stellt die Cron-Aufgabe für aktivierte Profile wieder her.
- Paket-Skripte werden mit der Firmware aktualisiert, nicht als alte Dateien über
  neue Versionen zurückkopiert. Vor jeder echten Aktualisierung Backup erstellen.

## Standortaufnahme: Reihenfolge

1. Einzigartige Routerkennung und freie Tunneladresse zentral festhalten.
2. Auf dem neuen Router WireGuard-Schlüssel erzeugen; nur Public Key zum Pi.
3. Am Pi exakt diesen Peer mit dessen /32-Adresse aufnehmen. Für neue Router
   brauchen SSH-Proxy und Firewall am Pi jeweils passende Regeln/Portzuordnungen.
   Das Routerpaket ändert weder Pi noch Home Assistant.
4. Gateway-IPv4, aktuelle globale/ULA/link-local IPv6-Adressen, WAN-Zone und
   WAN-Interface am Standort ermitteln. IPv6-Adressen dürfen nicht fehlen.
5. `/etc/config/mango_management` auf dem Gerät mit folgenden Werten füllen:

| Option | Inhalt |
| --- | --- |
| endpoint_host | Erreichbare IPv4 oder DNS-Name des Pi-Endpunkts; außerhalb des eigenen LAN kein privater Heimnetz-Endpunkt |
| endpoint_port | WireGuard-UDP-Port |
| server_public_key | Öffentlicher WireGuard-Schlüssel des Pi |
| tunnel_address | Einzigartige IPv4-Tunneladresse des Routers, ohne CIDR |
| server_address | IPv4-Tunneladresse des Pi, ohne CIDR |
| gateway_ipv4 | IPv4-Adresse des lokalen Heimrouters/DNS-Servers |
| gateway_ipv6 | UCI-Liste aller lokalen/öffentlichen/link-local Heimrouter-Adressen |
| gateway_dns_name | Lokal am Heimrouter auflösbarer Name (FRITZ!Box: fritz.box) |
| uplink_zone | Tatsächlicher Name der Uplink-Firewallzone |
| uplink_interface / uplink6_interface | Logische Netifd-Uplink-Interfaces |
| monitor_public_key | Einzelner Ed25519-Public-Key des Monitorings |

6. Profil prüfen, dann Erstaufnahme ausdrücklich ausführen. Der Installer erzeugt
   vorher eine Sicherung unter `/root/vor-mango-management-*`. Bei einem erkannten
   Aktivierungsfehler stellt er die gesicherten Konfigurationsdateien wieder her.
   Stromausfälle/Prozessabbruch mit SIGKILL sind dadurch nicht transaktionssicher.
7. Pi-seitigen Handshake und SSH mit vorher überprüftem Router-Hostschlüssel testen.
   Niemals `StrictHostKeyChecking=no` verwenden. Keine private Schlüsseldatei teilen.
8. FRITZ-Verwaltung über IPv4/IPv6 testen und die REJECT-Zähler prüfen. DNS,
   Freifunk-VPN, Mesh sowie negatives Tunnel-Forwarding separat prüfen.
9. Neustarten, erneute Prüfung, Backup außerhalb des Routers ablegen.

## Grenzen

Die Sperre läuft auf dem Mango. Ein Angreifer mit Root-Zugriff kann sie entfernen;
sie ersetzt keine Netztrennung. Ein Präfixwechsel kann bis zur nächsten erfolgreichen
DNS-Prüfung eine Schutzlücke hinterlassen. IPv6-DNS kann Adressen auslassen;
insbesondere die link-local Adresse muss bei der Aufnahme korrekt ermittelt werden.
Andere Heimrouter, zusätzliche Verwaltungsports und geänderte LAN-/Hardware-Adressen
brauchen eine angepasste Standortkonfiguration.

Die öffentlichen Update-Dateien und das signierte Manifest bleiben unverändert.
Autoupdater bleibt deaktiviert. Backups und gestaffelte Updates auf dem Pi sind
separate, noch nicht implementierte Arbeitspunkte. Die neue Monitoring-Implementierung
für fastd/mesh0/client*-Interfaces muss auf dem Testgerät gegen die bisherigen
Home-Assistant-Werte geprüft werden.

## Lokale Prüfung und Build

Basis: Branch mango-test6-wireguard, Commit 9aea734 (vollständiger SHA im Git-Verlauf).
Vorgesehener Entwicklungsbranch: mango-dev-auto-security. Release: mango-test7.

```sh
python3 -m unittest discover -s tests -v
```

12 Tests: Shell-Syntax, Eingabevalidierung/Injection, enge UCI-Regeln, deaktivierter
Auslieferungszustand, SSH-Whitelist, DNS-Ausfall, leere DNS-Antwort, unveränderte
Adressen ohne Flash-Schreiben, neue Präfixe, Reload-Fehler, offene UCI-Änderungen.
UCI/Firewall werden in temporären Verzeichnissen simuliert; dies sind keine
Hardware-, netifd-, Kernel- oder vollständigen Wiederherstellungstests.
Die Site-Patches wurden in Workflow-Reihenfolge gegen den festgelegten Site-Commit
auf Anwendbarkeit geprüft; Workflow-YAML wurde geparst.

Der Workflow führt die Tests vor dem Build aus, kopiert das Paket in den Gluon-
Paketbaum und wählt es nur für gl-mt300n-v2 aus. Erst ein erfolgreicher Actions-Build
belegt, dass alle Paketabhängigkeiten und das Image zusammen gebaut werden können.
Danach ist ein Test auf einem separaten Mango erforderlich. Kein automatisches Flashen.

**Stand 15.11.2026:** Lokal vorbereitet und getestet. Die GitHub-Verbindung ist
jetzt mit Schreibrechten eingerichtet. Diese Fassung wird auf dem separaten
Entwicklungsbranch gebaut; den aktuellen Buildstatus zeigt GitHub Actions.
Noch kein Hardwaretest und keine Freigabe fuer automatische Updates.
