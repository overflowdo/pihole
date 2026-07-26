#!/usr/bin/env bash
# Prüft, dass *.apphost.lan auf die App-Host-VM (Traefik) auflöst.
# Nutzbar auf der Pi-hole-VM (Alias: 'verify'), vom PC oder aus einem Container.
#
#   ./verify-dns.sh [DNS-SERVER]
#     DNS-SERVER   Pi-hole-IP, gegen die getestet wird (Default: 192.168.178.5)
#
# Überschreibbar per Env:  EXPECTED_IP, WILDCARD_DOMAIN
set -uo pipefail

DNS_SERVER="${1:-192.168.178.5}"
WILDCARD_DOMAIN="${WILDCARD_DOMAIN:-apphost.lan}"
EXPECTED_IP="${EXPECTED_IP:-192.168.178.45}"

# Aus der Aufgabenstellung: Dienste laufen als diese Subdomains + Domain selbst.
NAMES=(
  apphost dashboard traefik
  auth cloud office wopi photos jellyfin
  paperless grafana prometheus alertmanager ntfy speedtest vault bichon
)

R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; N='\033[0m'

# dig/nslookup fragen den angegebenen Server direkt; getent nur als Fallback
# (nutzt den System-Resolver, nicht zwingend $DNS_SERVER).
resolve() {
  local host="$1"
  if command -v dig >/dev/null 2>&1; then
    dig +short +time=2 +tries=1 A "$host" "@${DNS_SERVER}" 2>/dev/null | grep -E '^[0-9]' | tail -n1
  elif command -v nslookup >/dev/null 2>&1; then
    nslookup "$host" "$DNS_SERVER" 2>/dev/null | awk '/^Address: /{a=$2} END{print a}'
  else
    getent hosts "$host" 2>/dev/null | awk '{print $1}' | head -n1
  fi
}

echo -e "DNS-Server: ${DNS_SERVER}    erwartete IP: ${EXPECTED_IP}    Domain: *.${WILDCARD_DOMAIN}"
echo    "──────────────────────────────────────────────────────────────────"

fail=0
for n in "${NAMES[@]}"; do
  if [[ "$n" == "apphost" ]]; then
    fqdn="${WILDCARD_DOMAIN}"
  else
    fqdn="${n}.${WILDCARD_DOMAIN}"
  fi
  got="$(resolve "$fqdn")"
  if [[ "$got" == "$EXPECTED_IP" ]]; then
    printf "${G}  OK  ${N} %-30s -> %s\n" "$fqdn" "$got"
  else
    printf "${R} FEHL ${N} %-30s -> %s\n" "$fqdn" "${got:-<leer>}  (erwartet ${EXPECTED_IP})"
    fail=1
  fi
done

echo "──────────────────────────────────────────────────────────────────"
if [[ $fail -eq 0 ]]; then
  echo -e "${G}Alles gut: *.${WILDCARD_DOMAIN} zeigt auf ${EXPECTED_IP}.${N}"
else
  echo -e "${Y}Mindestens ein Name löst nicht wie erwartet auf.${N}"
  echo    "Checks: Pi-hole läuft (docker ps), FTLCONF_misc_etc_dnsmasq_d=true,"
  echo    "        Datei /etc/dnsmasq.d/10-apphost-wildcard.conf im Container,"
  echo    "        Client nutzt wirklich ${DNS_SERVER} als DNS."
fi
exit $fail
