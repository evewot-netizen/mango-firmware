#!/bin/bash
# User-requested plain archive for their private Google Drive folder.
set -euo pipefail
umask 077
test "$#" = 2 || { echo 'Usage: archive-pc-plain-for-cloud.sh OUTPUT_DIR WINDOWS_USER_DIR' >&2; exit 1; }
out=$(realpath "$1")
win=$(realpath "$2")
base=/home/Patrick
for tool in tar git sha256sum; do command -v "$tool" >/dev/null; done
test -d "$base/mango-firmware"
test -s "$base/mango-firmware-private/autoupdater/mango-autoupdater.secret"
test -s "$win/.ssh/mango_freifunk"
test -s "$win/.ssh/mango_freifunk.pub"
test -d "$out"
test -z "$(ls -A "$out")" || { echo 'Output directory must be empty.' >&2; exit 1; }
if pgrep -x make >/dev/null; then echo 'A build is running; stop it before archiving.' >&2; exit 1; fi
work=$(mktemp -d "$base/.mango-cloud-archive.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
trap 'exit 1' HUP INT TERM
mkdir -p "$work/data/Windows-SSH" "$work/data/Windows-Extras" "$work/data/Metadata"
cp -- "$win/.ssh/mango_freifunk" "$win/.ssh/mango_freifunk.pub" "$work/data/Windows-SSH/"
if test -f "$win/.ssh/known_hosts"; then cp -- "$win/.ssh/known_hosts" "$work/data/Windows-SSH/"; fi
for name in zz-mango-uplink mango-neu-01-pakete mango-neu-01-usb mango-usb-treiber; do
    item="$win/AppData/Local/Temp/$name"
    if test -e "$item" || test -L "$item"; then cp -a -- "$item" "$work/data/Windows-Extras/"; fi
done
item="$win/Downloads/Mango-Sicherung-20261115-032233"
if test -d "$item"; then cp -a -- "$item" "$work/data/Windows-Extras/"; fi

excluded=(
    mango-firmware/gluon/openwrt/build_dir
    mango-firmware/gluon/openwrt/staging_dir
    mango-firmware/gluon/openwrt/dl
    mango-firmware/gluon/openwrt/tmp
    mango-firmware/gluon/tmp
)
options=()
for path in "${excluded[@]}"; do options+=("--exclude=$path"); done
printf '%s\n' "${excluded[@]}" > "$work/data/Metadata/excluded-build-directories.txt"
echo '--- Projektstaende dokumentieren ---'
find "$base/mango-firmware" -maxdepth 3 -name .git -print -prune |
while IFS= read -r marker; do
    repo=${marker%/.git}
    printf '\n--- %s ---\n' "$repo"
    git -C "$repo" rev-parse HEAD
    git -C "$repo" status --short --untracked-files=normal
done > "$work/data/Metadata/git-status.txt"

archive="$out/Mango-PC-Archiv.tar.gz"
echo '--- Sicherung ohne Zusatzpasswort erstellen ---'
tar --create --gzip --file="$archive.part" "${options[@]}" \
    -C "$base" mango-firmware mango-firmware-private \
    -C "$work/data" Windows-SSH Windows-Extras Metadata

echo '--- Archiv und Schluessel pruefen ---'
tar -tzf "$archive.part" > "$work/archive-content.txt"
for member in \
    mango-firmware-private/autoupdater/mango-autoupdater.secret \
    Windows-SSH/mango_freifunk Windows-SSH/mango_freifunk.pub
do
    grep -Fxq "$member" "$work/archive-content.txt"
    if [[ "$member" == Windows-SSH/* ]]; then source="$work/data/$member"; else source="$base/$member"; fi
    actual=$(tar -xOzf "$archive.part" "$member" | sha256sum | cut -d' ' -f1)
    expected=$(sha256sum "$source" | cut -d' ' -f1)
    test "$actual" = "$expected" || { echo "Archive verification failed: $member" >&2; exit 1; }
done
for path in "${excluded[@]}"; do
    if grep -Fq "$path/" "$work/archive-content.txt"; then
        echo "Unexpected build directory in archive: $path" >&2; exit 1
    fi
done
mv -- "$archive.part" "$archive"
cp -- "$work/archive-content.txt" "$out/Archiv-Inhalt.txt"
cat > "$out/WIEDERHERSTELLUNG.txt" <<'README'
Mango/Freifunk - PC-Sicherung ohne Zusatzpasswort

Enthalten:
- WSL-Projekt mit lokalen Aenderungen, Git-Daten, Patches und Firmwaredateien
- Privater Firmware-Signaturschluessel und zugehoerige Dateien
- Windows-SSH-Schluessel mango_freifunk, Public Key und vorhandene known_hosts
- Vorgefundene alte Windows-Mango-Sicherung und ausgewaehlte Temp-Dateien
- Metadata/git-status.txt und ausgeschlossene Build-Verzeichnisse

Nicht enthalten: die laufende Konfiguration und Backups auf dem Raspberry Pi.
Diese muessen separat aus Home Assistant gesichert werden.

Normales TAR.GZ-Archiv ohne Verschluesselung, wie vom Eigentuemer gewuenscht.

Wiederherstellung mit GNU tar:
1. SHA256-Pruefsumme kontrollieren: sha256sum -c SHA256SUMS.txt
2. Inhalt ansehen: tar -tzf Mango-PC-Archiv.tar.gz
3. In einen leeren, privaten Ordner entpacken:
   mkdir -m 700 Wiederherstellung
   tar -xzf Mango-PC-Archiv.tar.gz -C Wiederherstellung

WSL-Projekte lagen urspruenglich unter /home/Patrick/.
Git-Worktrees/Symlinks koennen diesen alten Pfad referenzieren. Bei abweichendem
Ziel nach dem Entpacken pruefen; ggf. git worktree repair benutzen.
Private SSH-Schluessel unter Linux mit chmod 600 schuetzen.
Niemals private Schluessel oder das unverschluesselte Archiv oeffentlich hochladen.

Die lokalen Quelldateien wurden durch dieses Sicherungsskript NICHT geloescht.
Vor ihrer Entfernung auch den tatsaechlichen Google-Drive-Upload pruefen.
README
(cd "$out" && sha256sum Mango-PC-Archiv.tar.gz Archiv-Inhalt.txt WIEDERHERSTELLUNG.txt > SHA256SUMS.txt)
echo 'ERFOLG: Archiv lesbar und beide privaten Schluessel geprueft.'
du -h "$archive"
echo 'Originaldateien unveraendert. Jetzt nach Google Drive kopieren.'
