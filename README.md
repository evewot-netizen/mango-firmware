# Mango Firmware
### Custom Gluon firmware for GL.iNet Mango | Freifunk Halle

**English 🇬🇧 | Deutsch 🇩🇪**

**Project status:** Experimental / Under development  
**Supported target device:** GL.iNet GL-MT300N-V2 (Mango)  
**Platform:** Gluon / OpenWrt  
**Community base:** Freifunk Halle  
**Build system:** GitHub Actions

> ⚠️ **Experimental firmware:** This is an independent development project. Firmware builds may contain bugs or incomplete features. They are not official releases of Freifunk Halle or GL.iNet.

---

# 🇬🇧 English

## About the Project

Mango Firmware is an independent, community-oriented firmware development project for the **GL.iNet GL-MT300N-V2 (Mango)** mini router.

The project is based on Gluon and the firmware configuration maintained by the Freifunk Halle community.

Its primary goal is to extend the capabilities of this small, low-power router, particularly through additional USB Wi-Fi hardware.

The long-term vision is to create a compact Freifunk router that can be deployed at different locations, use an existing wireless Internet connection, and eventually be monitored and maintained remotely.

## Main Objectives

### 1. USB Wi-Fi Support

The project explores support for additional USB wireless adapters, including the Netgear WNA1100.

The intended configuration is:

- Connect the Mango to an existing private Wi-Fi network using a USB Wi-Fi adapter.
- Use the router's internal wireless interface to provide a separate Freifunk network.
- Avoid requiring a permanent Ethernet connection for the upstream Internet connection.
- Investigate compatible drivers and hardware configurations.

USB adapter compatibility and reliable simultaneous operation are still under development and testing.

### 2. Freifunk Integration

The firmware builds use the Freifunk Halle Gluon and site configuration as their foundation.

The goal is to preserve the essential principles of Freifunk, including community networking, open access and decentralized infrastructure.

Compatibility with the community's current technical requirements must be verified for each custom build.

### 3. Automated Firmware Builds

The repository uses GitHub Actions to support firmware development and build automation.

Source references and configuration settings are maintained in `sources.env`.

This approach allows firmware changes to be tracked and tested without relying exclusively on manual compilation.

Development builds receive individual identifiers to help distinguish different experiments.

### 4. Secure Remote Administration — Planned

A future objective is to manage multiple Freifunk routers from a central administration system.

The planned architecture includes:

- A Raspberry Pi acting as a central management server.
- Monitoring routers at different geographical locations.
- Checking firmware and connection status.
- Controlled, staged firmware updates.
- Logging successful and failed update operations.
- Reducing the risk of simultaneous outages.

GitHub will remain responsible for source management and firmware builds.

The Raspberry Pi is intended to coordinate deployment and monitoring.

**This management system is planned and is not part of the currently completed firmware functionality.**

## Target Hardware

| Component | Specification |
|---|---|
| Device | GL.iNet GL-MT300N-V2 |
| Codename | Mango |
| Processor | MediaTek MT7628NN, 580 MHz |
| RAM | 128 MB |
| Flash storage | 16 MB |
| Internal Wi-Fi | 2.4 GHz, IEEE 802.11 b/g/n |
| USB | USB 2.0 |
| Firmware target | `ramips-mt76x8` |
| Gluon device | `gl-mt300n-v2` |

Additional USB wireless hardware is being evaluated separately.

## Repository Structure

| Path | Description |
|---|---|
| `.github/workflows/` | GitHub Actions build automation |
| `patches/` | Project-specific modifications |
| `docs/updates/` | Update-related documentation |
| `sources.env` | Upstream repositories, pinned revisions and build settings |
| `README.md` | Project documentation |

## Development Status

This project is experimental.

Current development and testing focus on:

- Custom Gluon firmware builds for the Mango.
- USB Wi-Fi drivers and adapter support.
- Network interface configuration.
- Mesh and VPN connectivity.
- WireGuard-related development experiments.
- Firmware build verification and repeatable testing.

A successful GitHub Actions build does not automatically mean that all features work correctly on physical hardware.

There is currently no general guarantee that experimental builds are suitable for production use.

## Building and Testing

1. Review the repository's source references and build configuration.
2. Inspect the GitHub Actions workflows.
3. Select the appropriate development branch.
4. Run the relevant build workflow.
5. Download and inspect the resulting build artifacts.
6. Verify the exact device target before attempting installation.
7. Test on a device that can be recovered if flashing fails.

**Important:** Never flash an image intended for a different hardware model. Back up relevant configuration data before changing firmware.

## Security and Updates

Custom firmware may introduce security, stability or connectivity issues.

Before using experimental builds:

- Verify that private and public network interfaces are correctly separated.
- Check firewall and routing behavior.
- Do not expose private management services unintentionally.
- Review upstream security advisories.
- Verify update behavior before enabling automatic deployment.

The `main` branch currently has the Gluon automatic updater disabled in `sources.env`. Other branches may use different settings.

Remote update automation should only be introduced after reliable recovery and rollback procedures have been evaluated.

## Roadmap

- [ ] Improve and validate USB Wi-Fi support.
- [ ] Verify wireless uplink and Freifunk access point operation.
- [ ] Continue VPN and WireGuard experiments.
- [ ] Improve firmware build identification and documentation.
- [ ] Expand hardware and stability testing.
- [ ] Develop Raspberry Pi-based central monitoring.
- [ ] Implement controlled, staged remote updates.
- [ ] Document recovery procedures and known limitations.

These are development goals, not promises of future releases.

## Upstream Projects and Acknowledgements

This project builds upon the work of the open-source and Freifunk communities.

Relevant upstream repositories:

- [Freifunk Halle — Gluon Changes](https://github.com/FreifunkHalle/gluon-changes)
- [Freifunk Halle — Site Configuration](https://github.com/FreifunkHalle/site-ffhal)
- [Freifunk Halle — Gluon Packages](https://github.com/FreifunkHalle/gluon-package)
- [Gluon Documentation](https://gluon.readthedocs.io/)

Many thanks to the volunteers and developers who maintain Freifunk, Gluon and OpenWrt.

**Disclaimer:** Mango Firmware is an independent project and is not officially maintained, supported or endorsed by Freifunk Halle or GL.iNet.

---

# 🇩🇪 Deutsch

## Über das Projekt

Mango Firmware ist ein unabhängiges, gemeinschaftsorientiertes Firmware-Entwicklungsprojekt für den Mini-Router **GL.iNet GL-MT300N-V2 (Mango)**.

Die technische Grundlage bilden Gluon und die Firmware-Konfiguration der Freifunk-Community Halle.

Das Hauptziel besteht darin, die Möglichkeiten dieses kleinen, stromsparenden Routers zu erweitern, insbesondere durch zusätzliche USB-WLAN-Hardware.

Langfristig soll ein kompakter Freifunk-Router entstehen, der an unterschiedlichen Standorten eingesetzt werden kann, eine vorhandene WLAN-Internetverbindung nutzt und zentral überwacht und gewartet werden kann.

## Hauptziele

### 1. Unterstützung für USB-WLAN

Das Projekt untersucht die Unterstützung zusätzlicher USB-WLAN-Adapter, darunter der Netgear WNA1100.

Die angestrebte Konfiguration:

- Verbindung des Mango mit einem vorhandenen privaten WLAN über einen USB-WLAN-Adapter.
- Bereitstellung eines getrennten Freifunk-WLANs über die interne WLAN-Schnittstelle.
- Betrieb ohne dauerhaft erforderliche Ethernet-Verbindung zum Internetrouter.
- Untersuchung kompatibler Treiber und Hardwarekonfigurationen.

Die zuverlässige Zusammenarbeit der WLAN-Schnittstellen befindet sich noch in der Entwicklung und Testphase.

### 2. Integration in Freifunk

Die Firmware basiert auf Gluon und der Standortkonfiguration von Freifunk Halle.

Ziel ist es, die grundlegenden Prinzipien von Freifunk zu erhalten: gemeinschaftliche Netzwerke, offener Zugang und dezentrale Infrastruktur.

Die technische Kompatibilität mit den aktuellen Anforderungen der Community muss bei jedem angepassten Firmware-Build überprüft werden.

### 3. Automatisierte Firmware-Erstellung

GitHub Actions unterstützt die automatisierte Erstellung und das Testen eigener Firmware-Versionen.

Die verwendeten Quellcode-Versionen und Build-Einstellungen werden in der Datei `sources.env` verwaltet.

Dadurch lassen sich Änderungen nachvollziehen, dokumentieren und gezielt testen.

Einzelne Entwicklungs-Builds erhalten unterscheidbare Kennungen.

### 4. Sichere Fernverwaltung — Geplant

Ein langfristiges Ziel besteht darin, mehrere Freifunk-Router von einer zentralen Verwaltungsstelle aus betreuen zu können.

Geplant sind:

- Ein Raspberry Pi als zentrale Verwaltungsinstanz.
- Überwachung mehrerer Router an unterschiedlichen geografischen Standorten.
- Kontrolle der Firmware-Versionen und Netzwerkverbindungen.
- Kontrollierte, zeitlich gestaffelte Firmware-Updates.
- Protokollierung erfolgreicher und fehlgeschlagener Aktualisierungen.
- Verringerung des Risikos gleichzeitiger Ausfälle.

GitHub soll weiterhin für die Verwaltung des Quellcodes und die Erstellung der Firmware zuständig bleiben.

Der Raspberry Pi soll später die Überwachung und Verteilung koordinieren.

**Diese Verwaltungsfunktionen sind geplant und derzeit noch kein fertig entwickelter Bestandteil des Projekts.**

## Zielhardware

| Komponente | Ausstattung |
|---|---|
| Gerät | GL.iNet GL-MT300N-V2 |
| Gerätename | Mango |
| Prozessor | MediaTek MT7628NN, 580 MHz |
| Arbeitsspeicher | 128 MB |
| Flash-Speicher | 16 MB |
| Internes WLAN | 2,4 GHz, IEEE 802.11 b/g/n |
| USB-Anschluss | USB 2.0 |
| Firmware-Zielplattform | `ramips-mt76x8` |
| Gluon-Geräteprofil | `gl-mt300n-v2` |

Zusätzliche USB-WLAN-Hardware wird gesondert untersucht.

## Aufbau des Repositorys

| Verzeichnis / Datei | Funktion |
|---|---|
| `.github/workflows/` | Automatisierte Firmware-Builds mit GitHub Actions |
| `patches/` | Projektspezifische Anpassungen |
| `docs/updates/` | Dokumentation zu Aktualisierungen |
| `sources.env` | Quellcode-Versionen und Build-Einstellungen |
| `README.md` | Projektbeschreibung |

## Aktueller Entwicklungsstand

Das Projekt befindet sich in einer experimentellen Entwicklungsphase.

Zu den aktuellen Arbeitsgebieten gehören:

- Eigene Gluon-Firmware-Builds für den Mango.
- Treiber und Unterstützung für USB-WLAN.
- Konfiguration der Netzwerkschnittstellen.
- Mesh- und VPN-Verbindungen.
- Experimente mit WireGuard.
- Überprüfung und Wiederholbarkeit der Firmware-Builds.

Ein erfolgreich abgeschlossener Build auf GitHub bedeutet nicht automatisch, dass sämtliche Funktionen auf dem Router fehlerfrei arbeiten.

Experimentelle Versionen sind nicht grundsätzlich für einen dauerhaften Produktiveinsatz geeignet.

## Firmware erstellen und testen

1. Quellcode-Verweise und Einstellungen prüfen.
2. Die vorhandenen GitHub-Actions-Workflows untersuchen.
3. Den passenden Entwicklungszweig auswählen.
4. Den entsprechenden Firmware-Build starten.
5. Die erstellten Dateien herunterladen und überprüfen.
6. Vor einer Installation das genaue Gerätemodell kontrollieren.
7. Tests ausschließlich auf Geräten durchführen, für die eine Wiederherstellung möglich ist.

**Wichtig:** Niemals eine Firmware für ein anderes Routermodell installieren. Vor Änderungen sollten wichtige Einstellungen gesichert werden.

## Sicherheit und Aktualisierungen

Eigene Firmware kann Fehler enthalten, die die Sicherheit, Stabilität oder Verbindung beeinträchtigen.

Vor der Verwendung experimenteller Versionen sollten insbesondere folgende Punkte geprüft werden:

- Trennung des privaten Netzwerks vom öffentlichen Freifunk-Netz.
- Firewall- und Routing-Einstellungen.
- Schutz privater Verwaltungszugänge.
- Aktuelle Sicherheitshinweise der zugrunde liegenden Projekte.
- Zuverlässigkeit des Aktualisierungsvorgangs.

Im Entwicklungszweig `main` ist der automatische Gluon-Updater derzeit über `sources.env` deaktiviert. Andere Entwicklungszweige können abweichende Einstellungen enthalten.

Automatisierte Fernaktualisierungen sollen erst eingeführt werden, wenn sichere Wiederherstellungs- und Rückfallverfahren untersucht wurden.

## Geplante Entwicklung

- [ ] USB-WLAN-Unterstützung verbessern und überprüfen.
- [ ] WLAN-Uplink und gleichzeitigen Freifunk-Betrieb testen.
- [ ] VPN- und WireGuard-Experimente fortsetzen.
- [ ] Build-Kennzeichnungen und Dokumentation verbessern.
- [ ] Stabilitätstests mit verschiedenen Hardwarekonfigurationen durchführen.
- [ ] Zentrale Überwachung über Raspberry Pi entwickeln.
- [ ] Kontrollierte, gestaffelte Fernaktualisierungen umsetzen.
- [ ] Wiederherstellungsverfahren und bekannte Einschränkungen dokumentieren.

Die genannten Punkte sind Entwicklungsziele und keine verbindlichen Zusagen für zukünftige Veröffentlichungen.

## Verwendete Projekte und Danksagung

Mango Firmware baut auf der Arbeit zahlreicher Entwickler und freiwilliger Helfer aus der Open-Source- und Freifunk-Gemeinschaft auf.

Wichtige Grundlagen:

- [Freifunk Halle — Gluon Changes](https://github.com/FreifunkHalle/gluon-changes)
- [Freifunk Halle — Standortkonfiguration](https://github.com/FreifunkHalle/site-ffhal)
- [Freifunk Halle — Gluon-Pakete](https://github.com/FreifunkHalle/gluon-package)
- [Gluon-Dokumentation](https://gluon.readthedocs.io/)

Vielen Dank an alle, die Freifunk, Gluon und OpenWrt entwickeln und betreiben.

**Hinweis:** Mango Firmware ist ein unabhängiges Projekt. Es wird weder offiziell von Freifunk Halle noch von GL.iNet entwickelt, betreut oder unterstützt.

---

## Project Maintainer / Projektverwaltung

Maintained as an independent development project by [evewot-netizen](https://github.com/evewot-netizen).

Feedback, technical discussions and contributions are welcome through GitHub Issues and Pull Requests.

Rückmeldungen, technische Diskussionen und Verbesserungsvorschläge sind über GitHub Issues und Pull Requests willkommen.
