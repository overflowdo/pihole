# Pi-hole – Wildcard-DNS für `apphost.lan`

Deklarativ provisionierte, gehärtete **NixOS-VM** auf Proxmox, die per **Wildcard**
ganz `*.apphost.lan` auf die App-Host-VM (Traefik, `192.168.178.45`) auflöst und
netzweit als DNS dient. Löst zwei Probleme des Homelabs:

1. Dashboard-Kacheln „not found", weil `*.apphost.lan` nirgends auflöst.
2. OIDC-Login (`auth.apphost.lan`) scheitert, weil App-Container den Namen nicht
   auflösen können (Server-zu-Server-Token-Call).

Bewusst am Schwester-Repo **[`apphost`](https://github.com/overflowdo/apphost)**
orientiert: gleiche Flake-/`disko`-/`lanzaboote`-Basis, dieselben Härtungs-Module,
dieselbe Bedienung (`pull` / `update` / `rebuild` / `up` / `down` / `status`) und
**kein Container läuft als root** (Docker `userns-remap`).

Die vollständige Anleitung liegt in **[Installationsanleitung.md](Installationsanleitung.md)**.

## Struktur

| Pfad                                       | Inhalt                                                                                       |
| ------------------------------------------ | -------------------------------------------------------------------------------------------- |
| [`flake.nix`](flake.nix)                   | Flake (nixpkgs 26.05, `disko`, `lanzaboote`) – definiert `nixosConfigurations.pihole`.       |
| [`nixos/`](nixos/)                         | NixOS-Systemkonfiguration: `configuration.nix`, `disko.nix`, Härtungs-Module, `install.sh`.  |
| [`nixos/modules/`](nixos/modules/)         | `docker.nix` (userns-remap), `security.nix`, `networking.nix`, `secureboot.nix`.             |
| [`docker-compose.yml`](docker-compose.yml) | Der gehärtete Pi-hole-Container (`cap_drop: [ALL]`, `no-new-privileges`, Limits).            |
| [`dnsmasq.d/`](dnsmasq.d/)                 | dnsmasq-Regeln (komplett read-only gemountet): apphost-Wildcard + `20-local-custom.conf` für **eigene** Namen/Routing. |
| [`scripts/`](scripts/)                     | `verify-dns.sh` – prüft `*.apphost.lan` von PC/VM/Container aus.                             |
| [`.env.example`](.env.example)             | Vorlage für `/opt/pihole/.env` (TZ, Admin-Passwort, Upstream).                              |
| [`renovate.json`](renovate.json)           | Renovate: pinnt das Pi-hole-Image automatisch auf Digests.                                  |

## Die Wildcard in einem Satz

```conf
# dnsmasq.d/10-apphost-wildcard.conf
address=/apphost.lan/192.168.178.45
```

Beantwortet `apphost.lan` **und jede** Subdomain (`auth.`, `cloud.`, `grafana.`, …)
mit `192.168.178.45`. Alles außerhalb von `apphost.lan` geht an den Upstream
(FritzBox), damit `fritz.box` & Co. weiter funktionieren.

**Eigene lokale Namen/Routing** kommen genauso dazu: das ganze `dnsmasq.d/` ist
gemountet, also eine `*.conf` bearbeiten (Vorlage `dnsmasq.d/20-local-custom.conf`)
und `up`/`restart` – versioniert im Repo, kann auch Wildcards. Details in der
[Installationsanleitung](Installationsanleitung.md#8-betrieb).

## Kurzüberblick Installation

1. Proxmox-VM anlegen: NixOS-Minimal-ISO, **UEFI/OVMF + TPM + Secure Boot**,
   1 vCPU / 1 GB RAM / **≥ 20 GB** Disk (VirtIO-SCSI), feste IP `192.168.178.5`.
2. In der VM das Repo klonen und `sudo bash nixos/install.sh` ausführen –
   partitioniert (`disko`), installiert NixOS, richtet Secure Boot ein, legt das
   Repo unter `/opt/pihole` ab und erzeugt ein zufälliges Pi-hole-Admin-Passwort.
3. Nach dem Neustart: `up` (startet den Pi-hole-Container), dann `verify`.
4. Netzweit umstellen: in der FritzBox den **Lokalen DNS-Server** auf
   `192.168.178.5` setzen (Details + Alternativen in der Anleitung).

Danach folgt – **im [`apphost`](https://github.com/overflowdo/apphost)-Repo, nicht
hier** – noch das TLS-Skip/CA-Trust für die OIDC-Clients (self-signed Zertifikat).
Siehe [Installationsanleitung.md → „Danach"](Installationsanleitung.md#danach-tls-für-oidc-im-apphost-repo).
