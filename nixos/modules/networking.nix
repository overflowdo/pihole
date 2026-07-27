{ config, pkgs, lib, ... }:
{
  # ── Statische IP ────────────────────────────────────────────────────────────
  # Bewusste Abweichung vom apphost-Repo (das per DHCP/Reservierung läuft):
  # Ein netzweiter DNS-Server MUSS eine feste, DHCP-unabhängige Adresse haben –
  # Clients tragen genau diese IP ein. Deklarativ via systemd-networkd.
  networking = {
    hostName    = "pihole";
    useDHCP     = false;
    useNetworkd = true;

    # Der Host selbst fragt die FritzBox (NICHT sich selbst) – vermeidet eine
    # Boot-Abhängigkeit zum erst später startenden Pi-hole-Container.
    nameservers = [ "192.168.178.1" ];

    firewall.enable = false;  # Manuelles nftables-Ruleset unten
  };

  systemd.network.networks."10-lan" = {
    matchConfig.Name = "en*";                       # ggf. an echten NIC anpassen (ens18)
    address = [
      "192.168.178.5/24"
      # ── IPv6 (ULA) ──────────────────────────────────────────────────────────
      # Aus dem FritzBox-ULA-Präfix fd6a:b598:8a8a::/64 (die ersten 4 Blöcke der
      # Heimnetz-ULA; der Rest wie 36e1:a9ff:fe17:9fe6 ist nur die Geräte-Kennung).
      # Pi-hole nimmt ::5 in diesem Präfix. GENAU diese Adresse (fd6a:b598:8a8a::5)
      # trägst du in der FritzBox als "Lokaler DNSv6-Server" ein.
      "fd6a:b598:8a8a::5/64"
    ];
    routes           = [ { Gateway = "192.168.178.1"; } ];
    linkConfig.RequiredForOnline = "routable";
  };

  # ── systemd-resolved AUS ────────────────────────────────────────────────────
  # apphost nutzt resolved mit DNS-over-TLS. Diese VM kann das NICHT: resolveds
  # Stub-Listener belegt 127.0.0.53:53 und würde mit dem Pi-hole-Container
  # kollidieren, der 0.0.0.0:53 bindet. Der Host resolvt daher direkt über die
  # FritzBox (s.o.), Pi-hole bedient das LAN.
  services.resolved.enable = false;

  # ── nftables Firewall (default-drop) ────────────────────────────────────────
  # Struktur wie apphost/networking.nix; geöffnet werden hier 53 (DNS) und 80
  # (Pi-hole-Admin) statt 80/443. Alles auf das lokale /24 beschränkt – dieser
  # Resolver ist NICHT offen ins Internet.
  networking.nftables = {
    enable = true;
    ruleset = ''
      table inet filter {
        # Container-Kommunikation (Docker-Bridges) erlauben
        chain docker_input {
          ip saddr 172.16.0.0/12 accept
          ip saddr 192.168.0.0/16 accept
        }

        chain input {
          type filter hook input priority 0; policy drop;

          # Etablierte Verbindungen
          ct state established,related accept

          # Loopback immer erlauben
          iif lo accept

          # Docker-interne Kommunikation
          jump docker_input

          # ICMPv4 begrenzt erlauben
          ip protocol icmp icmp type {
            echo-request,
            destination-unreachable,
            time-exceeded,
            parameter-problem
          } limit rate 5/second burst 10 packets accept

          # ICMPv6 für korrekte IPv6-Funktion
          ip6 nexthdr icmpv6 icmpv6 type {
            nd-neighbor-solicit,
            nd-neighbor-advert,
            nd-router-advert,
            destination-unreachable,
            packet-too-big,
            time-exceeded,
            parameter-problem
          } limit rate 10/second burst 20 packets accept

          # SSH – nur aus dem LAN, ratenbegrenzt
          ip saddr 192.168.178.0/24 tcp dport 22 ct state new limit rate 5/minute burst 10 packets accept

          # DNS (IPv4) – nur aus dem LAN (kein offener Resolver!)
          ip saddr 192.168.178.0/24 tcp dport 53 accept
          ip saddr 192.168.178.0/24 udp dport 53 accept

          # DNS (IPv6) – aus dem LAN: ULA (fd00::/8) + Link-Local (fe80::/10).
          # (Bei host-networking lauscht FTL direkt am Host -> Queries hier im input.)
          ip6 saddr fd00::/8  tcp dport 53 accept
          ip6 saddr fd00::/8  udp dport 53 accept
          ip6 saddr fe80::/10 tcp dport 53 accept
          ip6 saddr fe80::/10 udp dport 53 accept

          # Pi-hole-Admin-Weboberfläche – nur aus dem LAN
          ip saddr 192.168.178.0/24 tcp dport 80 accept

          # Alles andere DROP + Logging
          log prefix "[nftables DROP] " level warn
        }

        chain forward {
          type filter hook forward priority 0; policy drop;

          # Etablierte Verbindungen
          ct state established,related accept

          # LAN -> Container (DNAT der veröffentlichten Ports 53/80) und
          # Container -> außen. Ohne diese beiden Zeilen erreicht die per DNAT
          # weitergeleitete DNS-Anfrage den Pi-hole-Container nicht.
          ip saddr 192.168.0.0/16 accept
          ip saddr 172.16.0.0/12  accept
        }

        chain output {
          type filter hook output priority 0; policy accept;
        }
      }

      table ip nat {
        chain postrouting {
          type nat hook postrouting priority srcnat; policy accept;

          ip saddr 172.16.0.0/12  masquerade
          ip saddr 192.168.0.0/16 masquerade
        }
      }
    '';
  };

  # Fail2ban mit nftables-Backend
  services.fail2ban.banaction           = "nftables-multiport";
  services.fail2ban.banaction-allports  = "nftables-allports";
}
