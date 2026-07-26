#!/usr/bin/env bash
# Installiert die gehärtete Pi-hole-VM (Wildcard-DNS für apphost.lan).
# Angelehnt an apphost/nixos/install.sh – gleicher Ablauf (disko -> nixos-install
# -> Secure Boot -> /opt/pihole als aktualisierbares Git-Repo), aber ohne den
# Dienst-Secrets-Teil: Pi-hole braucht nur EIN Admin-/API-Passwort.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NIX_FLAGS=(--extra-experimental-features "nix-command flakes")
APP_DIR=/mnt/opt/pihole

# Ein bisschen Farbe.
R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m' B='\033[0;34m' N='\033[0m'
info()  { echo -e "${G}▶${N}  $*"; }
warn()  { echo -e "${Y}⚠${N}  $*"; }
err()   { echo -e "${R}✖${N}  $*" >&2; exit 1; }

# Vorbedingungen
[[ $EUID -ne 0 ]] && err "Bitte als root ausführen: sudo bash nixos/install.sh"
[[ -f "$REPO_DIR/flake.nix" ]] || err "Kein Repo-Root gefunden (flake.nix fehlt in $REPO_DIR)"

cd "$REPO_DIR"

echo ""
echo "  Repo:    $REPO_DIR"
echo "  Dieses Skript:"
echo "  - partitioniert eine Festplatte (GPT + EFI + Swap + Btrfs)"
echo "  - installiert NixOS mit der gehärteten Pi-hole-Konfiguration"
echo "  - legt das Pi-hole-Repo unter /opt/pihole ab (per 'git pull' aktualisierbar)"
echo "  - erzeugt ein zufälliges Pi-hole-Admin-Passwort in /opt/pihole/.env"
echo ""

echo ""
echo "  Bitte wählen Sie ein sicheres Passwort für Ihren Nutzer 'pihole'."
echo "  Dieses Passwort wird für 'sudo' benötigt (zweiter Faktor nach SSH-Key)."
echo ""

if [[ $# -ge 3 ]]; then
  HASHED_PASSWORD="$3"
  info "Passwort-Hash Argument gesetzt, überspringe."
else
  while true; do
    read -rsp "  Passwort: " PW1; echo ""
    read -rsp "  Passwort bestätigen: " PW2; echo ""
    [[ "$PW1" == "$PW2" ]] && break
    warn "Passwörter stimmen nicht überein. Bitte erneut eingeben."
  done
  HASHED_PASSWORD="$(printf '%s' "$PW1" | nix run "${NIX_FLAGS[@]}" nixpkgs#mkpasswd -- -m sha-512 -s)"
  unset PW1 PW2
fi
echo "Passwort-Hash erzeugt"

echo ""
warn "WARNUNG: ALLE DATEN auf der Festplatte werden UNWIDERRUFLICH GELÖSCHT!"
echo ""
read -rp "  Bitte 'ja' eingeben um fortzufahren: " CONFIRM
[[ "$CONFIRM" == "ja" ]] || { echo ""; info "Abgebrochen."; exit 0; }

# Merker: Hash wird erst nach disko auf das Zielsystem geschrieben.
PIHOLE_PW_HASH="$HASHED_PASSWORD"

# hardware-configuration.nix Platzhalter (wird später überschrieben)
info "Erstelle hardware-configuration.nix Platzhalter..."
cat > nixos/hardware-configuration.nix << 'NIXEOF'
{ modulesPath, ... }:
{ imports = [ (modulesPath + "/installer/scan/not-detected.nix") ]; }
NIXEOF

# Festplattenverschlüsselung
echo ""
echo "  Optional kann die Root-Partition zusätzlich mit LUKS2 verschlüsselt werden."
echo "  Achtung: Danach wird bei JEDEM Boot eine Passphrase über die Server-Konsole benötigt"
echo "  > Kein unbeaufsichtigter Neustart ohne Konsolenzugriff (z.B. Proxmox-Konsole)."
echo ""
read -rp "  Festplattenverschlüsselung aktivieren? [j/N]: " ENC_ANSWER
if [[ "$ENC_ANSWER" =~ ^[jJyY] ]]; then
  DISK_ENCRYPTION=true
  warn "Festplattenverschlüsselung aktiviert. Die Passphrase wird bei der Formatierung festgelegt."
else
  DISK_ENCRYPTION=false
  info "Festplattenverschlüsselung deaktiviert (Standard)."
fi
cat > "$REPO_DIR/nixos/disk-encryption.nix" << NIXEOF
# Automatisch von nixos/install.sh gesetzt. Umschalten nur bei einer Neuinstallation sinnvoll.
$DISK_ENCRYPTION
NIXEOF

# SSH Public Key (einziger Zugangsweg – Passwort-Login ist deaktiviert!)
SSH_KEY_REGEX='^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com) [A-Za-z0-9+/]+=*( .*)?$'
if [[ $# -ge 4 ]]; then
  SSH_PUBKEY="$4"
  info "SSH Public Key Argument gesetzt, überspringe."
else
  while true; do
    read -rp "  SSH Public Key: " SSH_PUBKEY
    [[ "$SSH_PUBKEY" =~ $SSH_KEY_REGEX ]] && break
    warn "Das sieht nicht wie ein gültiger SSH Public Key aus (z.B. 'ssh-ed25519 AAAA...'). Bitte erneut."
  done
fi
cat > "$REPO_DIR/nixos/ssh-key.nix" << NIXEOF
# Automatisch von nixos/install.sh gesetzt. Nachträglich änderbar durch Bearbeiten
# dieser Datei und anschließend:  sudo nixos-rebuild switch --flake /opt/pihole#pihole
[
  "$SSH_PUBKEY"
]
NIXEOF
info "SSH Public Key gespeichert"

# disko Partitionierung
info "Starte disko (Partitionierung + Btrfs-Formatierung)..."
nix run "${NIX_FLAGS[@]}" github:nix-community/disko \
  -- --mode disko "$REPO_DIR/nixos/disko.nix"
info "Festplatte partitioniert und unter /mnt gemountet"

# Passwort-Hash auf das Zielsystem schreiben (außerhalb des Repos)
mkdir -p /mnt/etc
printf '%s' "$PIHOLE_PW_HASH" > /mnt/etc/pihole-password-hash
chmod 600 /mnt/etc/pihole-password-hash
info "Passwort-Hash nach /mnt/etc/pihole-password-hash geschrieben"

# fileSystems/swapDevices/luks verwaltet disko deklarativ -> aus der generierten
# hardware-configuration.nix herausfiltern (sonst Konflikte).
info "Generiere nixos/hardware-configuration.nix..."
nixos-generate-config \
  --root /mnt \
  --show-hardware-config \
  | awk '
      /^  fileSystems\./          { skip = 1 }
      skip && /^    \};/          { skip = 0; next }
      skip                        { next }
      /^  swapDevices /           { next }
      /^  boot\.initrd\.luks\.devices\./ { next }
      { print }
    ' > nixos/hardware-configuration.nix
info "hardware-configuration.nix generiert"

# ---- NixOS installieren ----
# Flake aus $REPO_DIR evaluieren (außerhalb von /mnt), sonst NAR-Hash-Konflikt.
info "Starte nixos-install ohne Bootloader (dauert einen Moment)..."
# --no-bootloader: lanzaboote braucht die Secure-Boot-Schlüssel, die es noch nicht
# gibt. Wir erzeugen sie danach und installieren den Bootloader separat.
nixos-install \
  --root /mnt \
  --flake "path:$REPO_DIR#pihole" \
  --no-root-passwd \
  --no-bootloader \
  --option extra-experimental-features "nix-command flakes"
echo "NixOS erfolgreich installiert!"

# ---- Secure Boot ----
info "Generiere Secure Boot Schlüssel..."
nixos-enter --root /mnt -- bash -c '
  set -euo pipefail
  TARGET=/etc/secureboot/keys
  mkdir -p "$TARGET" /etc/sbctl
  SBCTL_CFG=/etc/sbctl/configuration.json
  [ -f "$SBCTL_CFG" ] || printf '"'"'{"db_path":"/etc/secureboot"}'"'"' > "$SBCTL_CFG"
  sbctl create-keys
  if [ ! -f "$TARGET/db/db.pem" ]; then
    for src in /usr/share/secureboot /etc/secureboot; do
      if [ -f "$src/keys/db/db.pem" ]; then
        cp -r "$src/keys/." "$TARGET/"; break
      fi
    done
  fi
  [ -f "$TARGET/db/db.pem" ] || { echo "FEHLER: Secure Boot Keys nicht gefunden!"; exit 1; }
' && info "Secure Boot Schlüssel erzeugt: /etc/secureboot" \
  || warn "sbctl fehlgeschlagen – nach dem Neustart manuell: sudo sbctl create-keys && sudo nixos-rebuild boot"

# ---- Bootloader installieren ----
info "Installiere Bootloader (lanzaboote signiert die EFI-Binaries)..."
if nixos-enter --root /mnt -- /nix/var/nix/profiles/system/bin/switch-to-configuration boot; then
  info "Bootloader installiert"
else
  warn "Bootloader-Installation fehlgeschlagen – nach dem Neustart manuell:"
  warn "  sudo nixos-rebuild boot --flake /opt/pihole#pihole"
fi

# ---- /opt/pihole als aktualisierbares Git-Repo einrichten ----
# Live-ISO ist ephemer, daher pauschal safe.directory setzen.
git config --global --add safe.directory '*'

MONOREPO_ROOT="$(git -C "$REPO_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
MONOREPO_REMOTE=""
[[ -n "$MONOREPO_ROOT" ]] && MONOREPO_REMOTE="$(git -C "$MONOREPO_ROOT" remote get-url origin 2>/dev/null || true)"

if [[ -n "$MONOREPO_REMOTE" ]]; then
  MONOREPO_BRANCH="$(git -C "$MONOREPO_ROOT" rev-parse --abbrev-ref HEAD)"
  info "Richte aktualisierbares Git-Repo unter /opt/pihole ein (Branch: $MONOREPO_BRANCH)..."
  mkdir -p /mnt/opt
  git clone --branch "$MONOREPO_BRANCH" "$MONOREPO_ROOT" "$APP_DIR"
  git -C "$APP_DIR" remote set-url origin "$MONOREPO_REMOTE"
  # Maschinenspezifische, gitignorte Dateien nachziehen (frisch in diesem Lauf erzeugt).
  for f in nixos/hardware-configuration.nix nixos/ssh-key.nix nixos/disk-encryption.nix; do
    cp "$REPO_DIR/$f" "$APP_DIR/$f"
  done
else
  warn "Kein Git-Remote gefunden. Kopiere Repo ohne Versionierung (kein 'git pull' möglich)."
  mkdir -p "$APP_DIR"
  cp -r "$REPO_DIR"/. "$APP_DIR"
fi

# ---- .env mit Pi-hole-Admin-Passwort erzeugen ----
info "Erzeuge /opt/pihole/.env mit einem zufälligen Admin-Passwort..."
# openssl ist auf dem Live-ISO nicht vorinstalliert -> via nix run.
PIHOLE_WEB_PW="$(nix run "${NIX_FLAGS[@]}" nixpkgs#openssl -- rand -base64 18)"
ENV_FILE="$APP_DIR/.env"
cp "$APP_DIR/.env.example" "$ENV_FILE"
# Passwort per Umgebungsvariable durchreichen (nicht als argv -> nicht in 'ps' sichtbar).
PIHOLE_WEB_PW="$PIHOLE_WEB_PW" nix run "${NIX_FLAGS[@]}" nixpkgs#python3 -- - "$ENV_FILE" << 'PYEOF'
import os, re, sys
env_file = sys.argv[1]
# $ -> $$, damit docker-compose die Variable nicht interpoliert
value = os.environ['PIHOLE_WEB_PW'].replace('$', '$$')
with open(env_file) as f: content = f.read()
content, n = re.subn(r'^(FTLCONF_webserver_api_password=).*', lambda m: m.group(1) + value,
                     content, flags=re.MULTILINE)
if not n: content += f'\nFTLCONF_webserver_api_password={value}\n'
with open(env_file, 'w') as f: f.write(content)
PYEOF
chmod 600 "$ENV_FILE"

# Besitzrechte für /opt/pihole setzen (docker compose läuft als 'pihole').
# Namen 'pihole'/'docker' lösen nur im Zielsystem auf -> via nixos-enter.
nixos-enter --root /mnt -- bash -c '
  set -euo pipefail
  chown -R pihole:docker /opt/pihole
  chmod 0750 /opt/pihole
  chmod 0600 /opt/pihole/.env
  # dnsmasq-Regeln müssen im Pi-hole-Container lesbar sein. Unter userns-remap
  # gehört der host-User pihole (UID 1000) NICHT zur Remap-Range, erscheint im
  # Container also als "nobody" – daher zählt nur world-readable. :ro-Mount +
  # 0644/0755 genügt; explizit absichern (chown ändert die Modes nicht):
  chmod 0755 /opt/pihole/dnsmasq.d
  chmod 0644 /opt/pihole/dnsmasq.d/*.conf
'
info ".env erstellt und Rechte gesetzt"

echo ""
echo -e "${G}Pi-hole-Installation erfolgreich abgeschlossen!${N}"
echo ""
echo -e "  ${B}Nach dem Neustart:${N}"
echo -e "  ${B}1.${N} SSH-Login:        ssh pihole@192.168.178.5"
echo -e "  ${B}2.${N} Pi-hole starten:  up            (= cd /opt/pihole && docker compose up -d)"
echo -e "  ${B}3.${N} Verifizieren:     verify        (= scripts/verify-dns.sh)"
echo -e "  ${B}4.${N} Admin-Passwort:   grep FTLCONF_webserver_api_password /opt/pihole/.env"
echo -e "     Web-UI:  http://192.168.178.5/admin"
echo ""

for i in 5 4 3 2 1; do
  echo -ne "\r  ${Y}Neustart in ${i} Sekunden... (Strg+C zum Abbrechen)${N}  "
  sleep 1
done
echo ""
reboot now
