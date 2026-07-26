#!/usr/bin/env bash
# Setzt kuratierte Blocklisten (Adlists) in Pi-hole und aktualisiert Gravity.
# Idempotent (INSERT OR IGNORE) – mehrfaches Ausführen schadet nicht.
# Alias auf der VM:  seed-lists
#
# Blocklisten leben in der gravity.db (im Volume), nicht in pihole.toml – daher
# nicht per FTLCONF. Die URLs hier sind aber im Repo versioniert -> nach einem
# Volume-Reset einfach 'seed-lists' erneut ausführen.
#
# Entfernen/Deaktivieren einer Liste: in der Web-UI (Lists) oder die Zeile hier
# löschen und in der UI abwählen. Weniger Listen = weniger RAM/False-Positives.
set -euo pipefail

CONTAINER="${PIHOLE_CONTAINER:-pihole}"

# Format: "URL|Kommentar"  (Kommentar ohne einfache Anführungszeichen!)
ADLISTS=(
  "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts|StevenBlack unified (Ads + Malware) – Default"
  "https://big.oisd.nl|OISD Big (Ads + Tracking, sehr wenige False-Positives)"
  "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/pro.txt|HaGeZi Pro (Ads + Tracking von bekannten Anbietern)"
  "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/tif.txt|HaGeZi Threat Intelligence (Malware + Phishing)"
)

command -v docker >/dev/null 2>&1 || { echo "docker nicht gefunden" >&2; exit 1; }
docker ps --format '{{.Names}}' | grep -qx "$CONTAINER" \
  || { echo "Container '$CONTAINER' läuft nicht – erst 'up'." >&2; exit 1; }

echo "▶ Setze Adlists in $CONTAINER ..."
for entry in "${ADLISTS[@]}"; do
  url="${entry%%|*}"
  comment="${entry#*|}"
  docker exec "$CONTAINER" pihole-FTL sqlite3 /etc/pihole/gravity.db \
    "INSERT OR IGNORE INTO adlist (address, enabled, comment) VALUES ('$url', 1, '$comment');"
  echo "  + $url"
done

echo "▶ Aktualisiere Gravity (lädt die Listen herunter, dauert einen Moment) ..."
docker exec "$CONTAINER" pihole -g

echo "✓ Fertig. Aktive Listen & Domain-Anzahl siehst du in der Web-UI unter 'Lists'"
echo "  oder:  docker exec $CONTAINER pihole-FTL sqlite3 /etc/pihole/gravity.db \\"
echo "         'SELECT enabled, address FROM adlist;'"
