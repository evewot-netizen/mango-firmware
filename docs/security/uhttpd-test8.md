# Mango Test8: begrenzte HTTP-Request-Header

Stand: 16.11.2026. Ziel: `2025.1-halle1-mango-test8`, GL-MT300N-V2.

## Korrektur

CVE-2026-102338 / GHSA-vhx4-3p5q-m59q: uhttpd begrenzt bisher einzelne
Headerzeilen, aber nicht deren Anzahl und Gesamtspeicher pro Anfrage. Der
ungepatchte Stand `2025-07-06 / 7e64e8b` ist in Test7 enthalten.

Der unveraenderte Upstream-Diff von
https://github.com/openwrt/uhttpd/commit/f6c2fcfa539de49ddf6de8f805110c8804602e98
begrenzt Anfragen auf 100 Header und insgesamt 16 KiB Headerdaten. Ueberschreitungen
werden vor dem Speichern mit HTTP 431 abgewiesen. OpenWrt-Paketrelease wird von
4 auf 5 erhoeht; die Quellrevision bleibt fest gebunden.

## Erhalt der Einrichtung

Basis ist `5af521e8be5bffd06c5a01c143ac5b4f73f13290`, einschliesslich der am
15.11. vorbereiteten Tunnel-Wiederaufnahme und Upgrade-Wiederherstellung.
USB-WLAN-Pakete, wpa-supplicant, WireGuard, hostapd-Sicherheitspatch und
Update-Kanal mango bleiben enthalten. Die lokalen Profile und Schluessel werden
vom bestehenden sysupgrade-/Pi-Backup-Ablauf erhalten. Kein privater Schluessel
kommt in das Repository.

## Pruefung und Freigabe

- Upstream-Patch passt auf die festgelegte uhttpd-Revision.
- Native HTTP-Tests in CI: normale Anfragen, 100/101 Header, 16-KiB-Grenze,
  erfolgreiche Anfrage nach Ablehnungen; nur Loopback, maximal ca. 17 KiB.
- Vorhandene Sicherheits- und Verwaltungsregressionstests.
- Firmware-Cross-Build und Inhalts-/Hashpruefung muessen erfolgreich sein.
- Ein Build allein ist keine Freigabe: erst geprueftes Image und signiertes
  Manifest im veroeffentlichten Kanal koennen die Pi-Runde um 21 Uhr ausloesen.
- Reihenfolge laut installierter Pi-Konfiguration: Mango Zuhause, dann Mango 02;
  Fehler stoppen die Runde. Kein Nachholen einer bereits abgeschlossenen Runde
  durch diese Quellaenderung.

Ein Neustart-/Upgrade-Test auf echter Hardware wurde fuer Test8 noch nicht
beobachtet. Die Uhrzeit des Firmwarebaus ist keine Zusage fuer eine erfolgreiche
Installation um 21 Uhr.
