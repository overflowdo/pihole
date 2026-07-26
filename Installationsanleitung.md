# Installations- & Betriebsanleitung – Pi-hole Wildcard-DNS

Diese VM stellt netzweit DNS bereit und löst per **Wildcard** ganz `*.apphost.lan`
auf die App-Host-VM (`192.168.178.45`, Traefik) auf.

- [1. Architektur](#1-architektur)
- [2. Voraussetzungen](#2-voraussetzungen)
- [3. Proxmox-VM anlegen](#3-proxmox-vm-anlegen)
- [4. Installation](#4-installation)
- [5. Nach dem Neustart](#5-nach-dem-neustart)
- [6. Netzweit DNS umstellen](#6-netzweit-dns-umstellen)
- [7. Verifizieren](#7-verifizieren)
- [8. Betrieb](#8-betrieb)
- [9. Härtung](#9-härtung)
- [Danach: TLS für OIDC (im apphost-Repo)](#danach-tls-für-oidc-im-apphost-repo)
- [10. Troubleshooting](#10-troubleshooting)

---

## 1. Architektur

```
                          Internet
                             │
                     ┌───────┴────────┐
                     │  FritzBox 7690 │  192.168.178.1
                     │  Router + DHCP │  DHCP → „Lokaler DNS-Server" = .5
                     └───────┬────────┘
             DNS an Clients  │  (Pi-hole .5)
      ┌────────────────┬─────┴──────────────┐
      │                │                     │
┌─────┴──────┐  ┌──────┴───────┐      ┌──────┴────────┐
│ LAN-Clients│  │  Pi-hole-VM  │      │  App-Host-VM  │
│ PC, Handy  │  │ 192.168.178.5│      │ 192.168.178.45│
└────────────┘  │  Wildcard:   │      │   Traefik     │
                │*.apphost.lan │      │  :80 / :443   │
                │   → .45      │      │  ┌──────────┐ │
                │  (Upstream:  │      │  │Container: │ │
                │   FritzBox)  │      │  │auth cloud │ │
                └──────┬───────┘      │  │grafana …  │ │
        *.apphost.lan  │  = .45       │  └──────────┘ │
                       └──────────────┼──────────────►│
                                      └───────────────┘
```

Der Pi-hole beantwortet `*.apphost.lan` selbst (lokal, kein Weiterleiten). Alles
andere leitet er an die FritzBox weiter, damit `fritz.box` & andere Gerätenamen
weiter auflösen.

---

## 2. Voraussetzungen

- Proxmox VE (hier 9.2), Zugriff auf die Weboberfläche.
- Eine freie, feste IP im LAN: **`192.168.178.5`** (im Repo voreingestellt; zum
  Ändern → [10. Troubleshooting](#10-troubleshooting)).
- Ein **SSH-Public-Key** (Passwort-Login ist deaktiviert – ohne Key kein Zugang!).
  Erzeugen z.B. mit `ssh-keygen -t ed25519`.
- NixOS-Minimal-ISO (https://nixos.org/download) im Proxmox-ISO-Storage.

---

## 3. Proxmox-VM anlegen

VM erstellen (Werte, die von den Defaults abweichen):

| Bereich   | Einstellung                                                            |
| --------- | ---------------------------------------------------------------------- |
| General   | Name `pihole`, z.B. VMID `105`                                          |
| OS        | NixOS-Minimal-ISO                                                       |
| System    | **BIOS: OVMF (UEFI)**, **EFI-Disk hinzufügen**, **TPM v2.0 hinzufügen** |
| System    | Machine `q35`, SCSI Controller `VirtIO SCSI single`                     |
| Disk      | `scsi0`, **≥ 20 GB** (siehe Hinweis unten), Discard/SSD-Emulation an    |
| CPU       | 1 vCPU (Typ `host`)                                                     |
| Memory    | 1024 MB (**für die Installation temporär ≥ 8192 MB** – siehe Hinweis)    |
| Network   | Bridge `vmbr0` (VirtIO)                                                 |

> **Disk-Größe:** Die Aufgabenstellung nennt 8 GB – das reicht für **Debian**, aber
> **nicht** für NixOS. Nix-Store + mehrere Generationen brauchen mehr. Nimm
> **≥ 20 GB** (32 GB komfortabel). `install.sh` legt die Partitionen selbst an.

> **RAM für die Installation (wichtig):** Der Live-Installer wertet die gesamte
> NixOS-Konfiguration im RAM aus (nixpkgs + lanzaboote/`rust-overlay` sind
> speicherhungrig) und nutzt zusätzlich einen **RAM-gestützten** Nix-Store
> (tmpfs ≈ halbes RAM). Mit 1–4 GB scheitert es je nach Phase mit
> `No space left on device` (tmpfs voll) **oder** `Killed` / OOM (Auswertung).
> Beides ist **nicht** die Disk. Gib der VM **für die Installation temporär 8 GB**
> RAM (Proxmox → VM → Hardware → Memory) und stelle sie nach dem finalen `reboot`
> wieder auf 1–2 GB zurück – der laufende Pi-hole braucht sie nicht.

> **Secure Boot:** Damit lanzaboote greift, in der VM-Firmware Secure Boot im
> **Setup-Modus** lassen (Werksschlüssel gelöscht). Nach der Installation enrollt
> lanzaboote die eigenen Schlüssel (`sbctl enroll-keys` bzw. beim ersten Boot).

Feste IP: entweder gibt `install.sh` sie deklarativ vor (bereits auf `.5`
konfiguriert, siehe `nixos/modules/networking.nix`) – **oder** zusätzlich eine
DHCP-Reservierung auf der FritzBox für die MAC der VM anlegen (Gürtel & Hosenträger).

---

## 4. Installation

VM von der NixOS-ISO booten. Im Live-System:

```bash
# Netz/DNS im Live-ISO sicherstellen (meist per DHCP schon da)
# Repo holen (dieses Repo):
sudo -i
nix-shell -p git --run 'git clone https://github.com/overflowdo/pihole /root/pihole'
cd /root/pihole

# Installation starten
bash nixos/install.sh
```

`install.sh` fragt nacheinander ab und erledigt dann automatisch:

1. **sudo-Passwort** für den Nutzer `pihole` (wird gehasht abgelegt).
2. **Festplattenverschlüsselung** (LUKS2) – optional, Default aus.
3. **SSH-Public-Key** – der einzige Login-Weg.
4. Partitionierung via **`disko`** (GPT + EFI + verschlüsselter Swap + Btrfs).
5. `nixos-install` der Konfiguration `#pihole`.
6. **Secure Boot**: Schlüssel erzeugen + Bootloader (lanzaboote) installieren.
7. Repo als **aktualisierbares Git-Repo unter `/opt/pihole`** ablegen
   (Remote = GitHub) – Grundlage für `pull` / `update`.
8. `/opt/pihole/.env` mit einem **zufälligen Pi-hole-Admin-Passwort** erzeugen.
9. Neustart.

> Läuft komplett unbeaufsichtigt weiter, sobald die vier Fragen beantwortet sind.

---

## 5. Nach dem Neustart

```bash
ssh pihole@192.168.178.5

up            # startet den Pi-hole-Container  (cd /opt/pihole && docker compose up -d)
docker ps     # pihole sollte "healthy" sein
verify        # prüft *.apphost.lan  (scripts/verify-dns.sh)
```

Admin-Passwort: `install.sh` fragt es ab (leer = Zufallspasswort, wird am Ende
angezeigt). Auslesen / **ändern** auf dem laufenden System – einfach in der `.env`
setzen, dann `up` (die `FTLCONF_…`-Variable überschreibt alles bei jedem Start):

```bash
grep FTLCONF_webserver_api_password /opt/pihole/.env     # aktuelles Passwort
# ändern:
nano /opt/pihole/.env      # FTLCONF_webserver_api_password=DEIN-PASSWORT
up                         # übernimmt es (Container wird neu erstellt)
# Web-UI:  http://192.168.178.5/admin
```

---

## 6. Netzweit DNS umstellen

Damit `*.apphost.lan` **überall** auflöst, müssen die Clients den Pi-hole (`.5`)
als DNS bekommen. Zwei Wege:

### Weg A (empfohlen): FritzBox verteilt Pi-hole per DHCP

FRITZ!OS 8 (das 7690 hat es) hat dafür ein eigenes Feld:

**Heimnetz → Netzwerk → Netzwerkeinstellungen → „Weitere Einstellungen" →
IPv4-Adressen → „Lokaler DNS-Server"** → `192.168.178.5` eintragen → **Übernehmen**.

> Der genaue Menüpfad wandert zwischen FRITZ!OS-Versionen. Suche nach dem Feld
> **„Lokaler DNS-Server"**; für IPv6 gibt es analog **„Lokaler DNSv6-Server"**.

Wichtige Punkte:

- **Nicht** als *Internet*-DNS eintragen (Internet → Zugangsdaten → DNS-Server)!
  Nur der **lokale** DNS-Server wird an die Clients verteilt. Sonst Loop-Gefahr,
  weil Pi-holes Upstream ja wieder die FritzBox ist.
- Clients übernehmen den neuen DNS erst mit dem **nächsten DHCP-Lease** – kurz
  WLAN trennen/neu verbinden oder Gerät neu starten.
- Pi-holes Upstream ist die FritzBox (`192.168.178.1`, siehe `.env`), damit
  `fritz.box` & andere lokale Namen weiter aufgelöst werden.

### Weg B (gezielt): nur die App-Host-VM auf Pi-hole zeigen lassen

Reicht, um das **OIDC-Problem** zu lösen (Container müssen `auth.apphost.lan`
auflösen). **Diese Änderung gehört ins [`apphost`](https://github.com/overflowdo/apphost)-Repo**, nicht hierher:

```nix
# apphost: nixos/modules/networking.nix
networking.nameservers = [ "192.168.178.5" ];   # Pi-hole zuerst

# Docker-Container zuverlässig auf Pi-hole (sonst nutzen sie ggf. den Host-Resolver
# oder einen Default). apphost nutzt bereits daemon.settings – dort ergänzen:
# virtualisation.docker.daemon.settings.dns = [ "192.168.178.5" ];
```

Danach auf der App-Host-VM `docker compose up -d` (Neustart der Container, damit
sie den neuen Resolver übernehmen).

---

## 7. Verifizieren

Ziel: `nslookup auth.apphost.lan` liefert `192.168.178.45` – von überall.

**Vom PC** (Windows/Linux/mac):
```bash
nslookup auth.apphost.lan 192.168.178.5
# bzw. nach Weg A einfach:  nslookup auth.apphost.lan
```

**Von der App-Host-VM:**
```bash
getent hosts auth.apphost.lan          # -> 192.168.178.45
```

**Aus einem Container** (der eigentliche OIDC-Knackpunkt):
```bash
docker exec grafana getent hosts auth.apphost.lan
# Falls getent im Image fehlt (Alpine/musl):
docker exec grafana nslookup auth.apphost.lan 2>/dev/null || \
docker exec grafana wget -qO- http://auth.apphost.lan >/dev/null && echo erreichbar
```

**Bequem** auf der Pi-hole-VM:
```bash
verify         # testet Domain + alle Dienst-Subdomains gegen .45
```

---

## 8. Betrieb

Alle Aliase (definiert in `nixos/configuration.nix`, wie im apphost-Repo):

| Alias           | Wirkung                                                                   |
| --------------- | ------------------------------------------------------------------------- |
| `up`            | `docker compose up -d` – Pi-hole starten                                   |
| `down`          | `docker compose down` – Pi-hole stoppen                                    |
| `restart`       | `docker compose restart`                                                   |
| `logs`          | `docker compose logs -f`                                                   |
| `status`        | `systemctl status docker` + `docker ps`                                    |
| `pull`          | `git pull` in `/opt/pihole` (neue Repo-Version holen)                      |
| `rebuild`       | `nixos-rebuild switch --flake path:/opt/pihole#pihole`                     |
| `rebuild-boot`  | dito, aber erst beim nächsten Boot aktiv (nach Kernel-Updates)             |
| `update`        | `pull` + `nix flake update` + `rebuild` (System-Update in einem)          |
| `pihole-update` | `docker compose pull && up` – neues Pi-hole-**Image** ziehen              |
| `gc`            | Nix-Store aufräumen (`--delete-older-than 30d`) + optimise                 |
| `pihole`        | Pi-hole-CLI im Container, z.B. `pihole status`, `pihole -t` (Live-Log)     |
| `verify`        | Wildcard-Auflösung prüfen                                                  |

### Eigene lokale Namen / Routing hinzufügen

Zwei Wege – für diesen deklarativen Aufbau ist **Weg 1 (Datei)** die richtige Wahl:

**Weg 1 – Datei im Repo (empfohlen, versioniert, kann Wildcards):**
Das ganze `dnsmasq.d/` ist read-only in den Container gemountet, Pi-hole v6 lädt
jede `*.conf` automatisch. Also eigene Einträge in `dnsmasq.d/20-local-custom.conf`
setzen (oder eine neue `dnsmasq.d/30-....conf` anlegen), dann `up` (bzw. `restart`):

```conf
address=/example.lan/192.168.178.60      # Wildcard: Domain + alle Subdomains
host-record=nas.lan,192.168.178.20       # genau ein Name -> IP
cname=git.apphost.lan,apphost.lan        # Alias auf bestehenden Namen
server=/firma.intern/10.0.0.53           # Domain an anderen DNS delegieren
```

Danach committen/`pull`en, damit der Stand im Repo landet. Ziel-IP von apphost
ändern? Einfach die Zeile in `dnsmasq.d/10-apphost-wildcard.conf` anpassen → `restart`.

**Weg 2 – eingebaute Pi-hole-Funktion (Web-UI, NICHT im Repo):**
`http://192.168.178.5/admin` → *Local DNS → DNS Records* (exakte A/AAAA-Namen)
bzw. *CNAME Records*; in v6 unter *Settings → All settings* auch `misc.dnsmasq_lines`
(rohe dnsmasq-Zeilen, inkl. Wildcards). **Aber:** diese Einträge liegen nur im
Container-Volume (`pihole.toml`), sind **nicht** im Git-Repo und weg bei einem
Volume-Reset. Außerdem kann die normale UI **keine Wildcards** (nur `dnsmasq_lines`).
Für einen reproduzierbaren Stand daher Weg 1 nutzen.

### Sicherheit & Werbeblocken

**Sicherheits-/Privacy-Einstellungen** stehen deklarativ als `FTLCONF_*` in
`docker-compose.yml` (DNSSEC, `domainNeeded`, `bogusPriv`, `blockESNI`,
Blocking-Modus, Cache, Admin-Session-Limits). Ändern → `up`. Ungültige Keys sind
ungefährlich (FTL loggt sie als „invalid" und ignoriert sie). Alle gültigen Keys:
```bash
docker exec pihole pihole-FTL --config
```
> Wirft nach dem Aktivieren von DNSSEC eine einzelne Domain `SERVFAIL`, ist deren
> DNSSEC upstream kaputt – dann `FTLCONF_dns_dnssec: "false"` setzen.

**Blocklisten (Ads/Tracking/Malware)** liegen in der `gravity.db` (nicht in
`pihole.toml`), daher nicht per `FTLCONF`. Reproduzierbar über das versionierte
Skript mit kuratierten Listen (StevenBlack, OISD, HaGeZi Pro + Threat-Intel):
```bash
seed-lists            # = bash /opt/pihole/scripts/seed-adlists.sh
```
Listen ändern → URLs in `scripts/seed-adlists.sh` anpassen, `seed-lists` erneut.
Nach einem Volume-Reset (`docker volume rm pihole_etc`) einmal `seed-lists`, um die
Listen wiederherzustellen. Einzelne False-Positives in der Web-UI unter *Domains*
freigeben.

---

## 9. Härtung

Übernommen aus dem apphost-Repo (identische Module/Optionen):

- **Kein Container als root:** Docker `userns-remap = "default"` + `dockremap`
  (Container-UID 0 → host-UID 100000+). Zusätzlich am Container `cap_drop: [ALL]`
  (nur 6 nötige Caps zurück) und `no-new-privileges`. Kein `user:`-Override –
  Pi-hole startet als *gemapptes* root (nötig für Init + Port-Bind), ist damit
  aber host-UID 100000, nicht echtes root. Rechte-Modell: `/etc/pihole` ist ein
  **Named Volume** (Docker vergibt die Rechte in der Remap-Range), `dnsmasq.d`
  ein **world-readable `:ro`-Bind-Mount** – beide für den Container zugreifbar,
  ohne den bind-mount-`chown`-Umweg, den apphost bei Authelia braucht.
- **Kernel:** Lockdown (`confidentiality`), `module.sig_enforce=1`, volle
  Spectre/Meltdown-Mitigations, IOMMU, Heap-Schutz, restriktive Sysctls; unnötige
  Module blacklisted (CIS).
- **Boot:** Secure Boot via **lanzaboote** (jede Generation signiert).
- **SSH:** nur Key, kein Root, nur starke Cipher/KEX (inkl. PQ-hybrid), Banner.
- **MAC/Audit:** AppArmor, `auditd` (CIS-Regeln), `fail2ban`, `AIDE`,
  `lockKernelModules`, `protectKernelImage`, sudo-Härtung.
- **Firewall:** nftables default-drop.
- **Disk:** Btrfs-Subvolumes, verschlüsselter Swap, optional LUKS2.

Bewusst **abgewichen** (und warum):

- **Kein gVisor/Kata/containerd/trivy** (apphost hat sie): fügen DNS-Latenz hinzu
  und sind für 1 vCPU / 1 GB RAM mit einem einzelnen vertrauenswürdigen Container
  überzogen. Image-Aktualität übernimmt Renovate.
- **Statische IP statt DHCP:** ein netzweiter Resolver muss DHCP-unabhängig
  erreichbar sein.
- **`systemd-resolved` AUS:** dessen Stub-Listener belegt `127.0.0.53:53` und
  würde mit dem Pi-hole-Container (`0.0.0.0:53`) kollidieren. Der Host resolvt
  daher direkt über die FritzBox.
- **Firewall öffnet 53/80 (statt 80/443)** und nur fürs lokale `/24` – der
  Resolver ist **nicht** offen ins Internet.

---

## Danach: TLS für OIDC (im apphost-Repo)

> **Wichtig:** Dieser Schritt gehört **nicht** in dieses Repo, sondern in den
> App-Host-Stack. Hier nur als Merker.

Sobald DNS steht, erreichen die Container `auth.apphost.lan` – der OIDC-Token-Call
scheitert dann aber noch am **self-signed Zertifikat** von Traefik.

**Sauber (empfohlen): die self-signed CA in den Containern vertrauen** statt TLS
zu deaktivieren – z.B. CA-Datei einhängen und je nach Runtime setzen:
`SSL_CERT_FILE` / `NODE_EXTRA_CA_CERTS` (Node) / `REQUESTS_CA_BUNDLE` (Python).

**Pragmatisch (TLS-Verify aus):**

- **Grafana:**
  ```yaml
  GF_AUTH_GENERIC_OAUTH_TLS_SKIP_VERIFY_INSECURE: "true"
  ```
- **OpenCloud (OCIS-Fork):** die „insecure"-Optionen des Proxy/OIDC, z.B.
  `OC_INSECURE: "true"` bzw. `PROXY_OIDC_INSECURE: "true"` /
  `WEB_OIDC_INSECURE: "true"` – exakte Variable in der OpenCloud-Doc prüfen.
- **Paperless-ngx:** hat **keinen** einfachen Skip-Verify-Schalter (nutzt Python
  `requests`/allauth). Hier besser den **CA-Trust-Weg**: CA einhängen und
  `REQUESTS_CA_BUNDLE=/pfad/zur/ca.pem` setzen.

---

## 10. Troubleshooting

**`*.apphost.lan` löst nicht auf**
- `docker ps` – läuft `pihole` und ist „healthy"?
- Wildcard im Container vorhanden?
  `docker exec pihole cat /etc/dnsmasq.d/10-apphost-wildcard.conf`
- `FTLCONF_misc_etc_dnsmasq_d=true` gesetzt? (docker-compose.yml) – ohne das liest
  Pi-hole v6 `/etc/dnsmasq.d/` **nicht**.
- Nutzt der Client wirklich `.5`? `nslookup auth.apphost.lan 192.168.178.5`
  gegentesten (fragt den Pi-hole direkt).

**Container-Crashloop: „Unable to set capabilities for pihole-FTL. Cannot run as non-root"**
- `unable to set CAP_SETFCAP … Operation not permitted`: Pi-hole will FTL als
  non-root (uid 1000) laufen lassen und dazu `setcap` aufs Binary anwenden. Das
  scheitert hier doppelt: `CAP_SETFCAP` ist nicht erlaubt, und `no-new-privileges`
  ignoriert File-Caps ohnehin beim `exec`.
- Fix (bereits in `docker-compose.yml`): `DNSMASQ_USER: "root"` – FTL läuft dann als
  Container-root, das unter `userns-remap` **host-UID 100000** ist (kein echtes
  root). Danach `down && up`.

**Container: viele „Operation not permitted" / „Permission denied" auf `/etc/pihole/…`**
- Ursache: das Named Volume `pihole_etc` wurde in einem früheren (non-root-)Fehlversuch
  mit gemischten Eigentümern befüllt; der Container darf fremde Dateien ohne `FOWNER`/
  `DAC_OVERRIDE` nicht anfassen. Beide Caps sind jetzt in `docker-compose.yml`.
- Sicherste Reparatur (frischer Pi-hole, kein echter Datenverlust – Gravity/Listen
  werden neu aufgebaut):
  ```bash
  down
  docker volume rm pihole_etc
  up
  ```

**`git pull` in `/opt/pihole`: „dubious ownership" oder „.git/FETCH_HEAD: keine Berechtigung"**
- Entsteht, wenn man versehentlich `sudo git pull` laufen lässt (legt root-Dateien in
  `.git/` an). Besitz wieder geradeziehen, dann ohne sudo pullen:
  ```bash
  sudo chown -R pihole:docker /opt/pihole
  cd /opt/pihole && git pull
  ```
  (Der `pull`-Alias nutzt ab dieser Version kein `sudo` mehr.)

**Sonstige FTL-/Rechte-Fehler beim Start**
- In `docker-compose.yml` unter `cap_add` testweise `DAC_OVERRIDE` und `FOWNER`
  ergänzen. `logs` zeigt die Ursache.

**„permission denied" auf `/etc/dnsmasq.d/...` oder `/etc/pihole` (userns-remap)**
- Rechte der Regel-Dateien prüfen (müssen world-readable sein, weil der host-User
  `pihole` im Container als „nobody" erscheint):
  ```bash
  ls -l /opt/pihole/dnsmasq.d           # Dir 0755, *.conf 0644
  chmod 0755 /opt/pihole/dnsmasq.d && chmod 0644 /opt/pihole/dnsmasq.d/*.conf
  # im Container gegenprüfen:
  docker exec pihole ls -l /etc/dnsmasq.d
  ```
- Named Volume verwaist (z.B. nach Umschalten von `userns-remap`)? Der Container
  sieht dann fremde UIDs in `/etc/pihole`. Sauber neu initialisieren:
  ```bash
  down && docker volume rm pihole_etc && up      # Pi-hole legt /etc/pihole neu an
  ```
- Host-seitig gehört der Volume-Inhalt der Remap-Range (100000+), das ist korrekt:
  `ls -l /var/lib/docker/*/volumes/pihole_etc/_data` zeigt UID 100000-ish.

**„No space left on device" während `install.sh` (vor dem Partitionieren)**
- **Nicht die Ziel-Disk!** Der Fehler kommt beim `nix run … mkpasswd` / der
  nixpkgs-Auswertung, also bevor `disko` überhaupt partitioniert. Ursache: der
  Live-ISO baut im **RAM-gestützten** Nix-Store (tmpfs), und 1 GB RAM ist zu wenig.
- Fix: VM-RAM in Proxmox temporär auf **8 GB** setzen, ISO neu booten,
  `sudo bash nixos/install.sh` erneut ausführen. Der Fehllauf hat nichts auf die
  Disk geschrieben. Nach dem finalen `reboot` RAM wieder auf 1–2 GB.

**`Killed` / abgebrochene SSH-Sitzung während `nixos-install` (OOM)**
- `nixos-install: line … Killed … nix … build` = OOM-Killer: der Nix-Prozess
  wurde wegen Speichermangel beendet (die Config-Auswertung mit lanzaboote/
  `rust-overlay` ist RAM-intensiv). Der SSH-Abbruch ist nur die Folge.
- Bestätigen: `sudo dmesg -T | grep -iE 'out of memory|killed process|oom' | tail`
  und `free -h` (Spalte *available*).
- **Achtung – tritt auch auf, wenn der Graph noch RAM-Reserve zeigt:** Ursache ist
  dann **Proxmox-Ballooning**. `MemTotal` bleibt hoch, aber der Balloon-Treiber gibt
  RAM an den (knappen) Host zurück → real verfügbar ist viel weniger, `available`
  in `free -h` ist klein. Fix:
  - Proxmox → VM → Hardware → **Memory: „Minimum memory" = „Memory"** (Ballooning
    aus) → die VM bekommt fix ihre 8 GB.
  - Sicherstellen, dass der **Host** ~8 GB frei hat; sonst die **apphost-VM für die
    einmalige Installation kurz stoppen**, danach wieder starten.
- Sicherheitsnetz: `install.sh` legt inzwischen automatisch einen temporären
  **8-GB-Swapfile auf der Zielplatte** an (fängt OOM-Spitzen auch bei knappem RAM
  ab, wird vor dem Reboot entfernt). Einfach `sudo bash nixos/install.sh` erneut.

**„NAR hash mismatch in input 'path:…'" während `nixos-install`**
- Ursache: fehlende `flake.lock` – Nix schreibt sie sonst mitten im Build in den
  `path:`-Quellbaum, wodurch dessen Hash kippt. Die aktuelle `install.sh` erzeugt
  die Lock-Datei automatisch vorab. Mit einer älteren Version einmalig manuell:
  ```bash
  cd ~/pihole
  nix flake lock --extra-experimental-features "nix-command flakes" "path:$PWD"
  sudo bash nixos/install.sh          # erneut; nixos-install findet nun die Lock
  ```
  Danach auf dem laufenden System einmalig `cd /opt/pihole && sudo nix flake lock`,
  damit auch `rebuild`/`update` die Lock haben.
- Tipp: die erzeugte `flake.lock` ins Repo committen – sie ist **nicht** in
  `.gitignore` und pinnt nixpkgs/disko/lanzaboote (reproduzierbare Builds).

**Boot landet im „Emergency Mode" / „root account is locked"**
- Eine Unit ist beim Boot gescheitert (Mount/Swap/Dienst). Ursache finden: im
  Boot-Screen **hochscrollen (Shift+Bild↑)** zur roten `[FAILED]`-Zeile kurz vor
  „Reached target Emergency Mode".
- Kommst du an keine Shell (root gesperrt), per **NixOS-ISO** booten und das Journal
  des letzten Boots lesen (Partition ggf. anpassen; ohne LUKS):
  ```bash
  sudo -i
  mount -o subvol=var /dev/sda3 /mnt                 # /var-Subvolume
  journalctl -D /mnt/log/journal -b -1 -p err --no-pager | tail -80
  ```
  (Mit LUKS zuerst `cryptsetup open /dev/sda3 cryptroot`, dann `/dev/mapper/cryptroot`.)
- Reparieren: Root-Subvolume mounten, `nixos-enter`, Config in `/opt/pihole` fixen,
  `nixos-rebuild boot --flake /opt/pihole#pihole`:
  ```bash
  mount -o subvol=root /dev/sda3 /mnt
  mount -o subvol=nix  /dev/sda3 /mnt/nix
  mount /dev/sda1 /mnt/boot
  nixos-enter --root /mnt
  ```
- Ab der aktuellen Version hat root ein **Konsolen-Passwort** (= das sudo-Passwort),
  damit der Emergency-Modus direkt nutzbar ist (SSH-Root bleibt deaktiviert).

**Port 53 belegt**
- `ss -tulpn | grep :53` – es darf **nur** der Docker-Publish sein. `resolved` ist
  in `networking.nix` deaktiviert; falls doch etwas lauscht, prüfen.

**FritzBox blockt `apphost.lan` (DNS-Rebind-Schutz)**
- Tritt nur auf, wenn die FritzBox selbst auflöst. Bei Weg A antwortet der Pi-hole
  direkt – normalerweise kein Problem. Falls doch: in der FritzBox unter
  **DNS-Rebind-Schutz** den Hostname `apphost.lan` als Ausnahme eintragen.

**Andere Ziel-IP / anderes Subnetz**
- Wildcard-IP: `dnsmasq.d/10-apphost-wildcard.conf`.
- Pi-hole-IP / Gateway / Subnetz: `nixos/modules/networking.nix`
  (statische Adresse, Firewall-Regeln), danach `rebuild`.
- Upstream: `FTLCONF_dns_upstreams` in `/opt/pihole/.env`, danach `up`.

**SSH-Key vergessen (ausgesperrt)**
- Über die Proxmox-Konsole einloggen (User `pihole` + sudo-Passwort),
  `nixos/ssh-key.nix` anpassen, `rebuild`.
