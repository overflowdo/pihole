#!/usr/bin/env bash
# Stellt kuratierte Blocklisten (Adlists) in Pi-hole sicher und aktualisiert
# Gravity NUR, wenn sich die Liste tatsächlich geändert hat.
#
# Auto-tauglich & idempotent: läuft automatisch bei jedem 'up' (siehe Alias) und
# ist gefahrlos beliebig oft ausführbar. Manuell: seed-lists
#
# Blocklisten leben in der gravity.db (im Volume), nicht in pihole.toml – daher
# nicht per FTLCONF. Die URLs hier sind aber im Repo versioniert -> nach einem
# Volume-Reset stellt der nächste 'up' sie automatisch wieder her.
set -euo pipefail

CONTAINER="${PIHOLE_CONTAINER:-pihole}"
GDB=/etc/pihole/gravity.db
WAIT_TRIES="${WAIT_TRIES:-60}"   # * 2s = bis zu 120s auf den Container warten

# Format: "URL|Kommentar"  (Kommentar ohne einfache Anführungszeichen!)
ADLISTS=(
  "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts|StevenBlack unified (Ads + Malware) - Default"
  "https://big.oisd.nl|OISD Big (Ads + Tracking, sehr wenige False-Positives)"
  "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/pro.txt|HaGeZi Pro (Ads + Tracking bekannter Anbieter)"
  "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/tif.txt|HaGeZi Threat Intelligence (Malware + Phishing)"
)

command -v docker >/dev/null 2>&1 || { echo "docker nicht gefunden" >&2; exit 1; }
_sql() { docker exec "$CONTAINER" pihole-FTL sqlite3 "$GDB" "$1"; }

# Auf Container + gravity.db warten (nach 'up'/Volume-Reset kurz nötig).
ready=0
for _ in $(seq 1 "$WAIT_TRIES"); do
  if docker exec "$CONTAINER" test -f "$GDB" 2>/dev/null; then ready=1; break; fi
  sleep 2
done
[[ "$ready" == 1 ]] || { echo "⚠ Container '$CONTAINER'/gravity.db nicht bereit – Seeding übersprungen." >&2; exit 0; }

before="$(_sql 'SELECT COUNT(*) FROM adlist;' 2>/dev/null || echo 0)"

for entry in "${ADLISTS[@]}"; do
  url="${entry%%|*}"; comment="${entry#*|}"
  _sql "INSERT OR IGNORE INTO adlist (address, enabled, comment) VALUES ('$url', 1, '$comment');"
done

after="$(_sql 'SELECT COUNT(*) FROM adlist;' 2>/dev/null || echo 0)"

if [[ "$after" != "$before" ]]; then
  echo "▶ Adlists: $((after - before)) neu -> aktualisiere Gravity (lädt herunter) ..."
  docker exec "$CONTAINER" pihole -g
  echo "✓ Blocklisten aktualisiert."
else
  echo "✓ Adlists unverändert – kein Download nötig (Wochen-Cron hält den Inhalt frisch)."
fi
