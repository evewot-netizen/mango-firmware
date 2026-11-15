# mango-firmware
Eigene Firmware-Builds für GL.iNet Mango mit USB-WLAN auf Basis von Freifunk Halle.

## Sicherheitsvorlage für neue Mangos (Test7)

Die wiederverwendbare Einrichtung befindet sich in `packages/mango-management`.
Standortdaten und Schlüssel werden erst auf dem jeweiligen Router eingerichtet.
Das Paket ist im Auslieferungszustand deaktiviert und überschreibt keine vorhandene
Einrichtung. Details, Grenzen und Abnahme: [Sicherheitsvorlage](docs/security/README.md).

Lokal prüfen: `python3 -m unittest discover -s tests -v`.
Diese Entwicklungsfassung ist noch nicht als Firmware gebaut oder auf einem Gerät
geprüft und nicht für ein automatisches Update veröffentlicht.
