{ config, pkgs, lib, ... }:
{
  imports = [
    ./hardware-configuration.nix
    ./modules/security.nix
    ./modules/docker.nix
    ./modules/networking.nix
    ./modules/secureboot.nix
  ];

  # System
  system.stateVersion = "26.05";

  nixpkgs.config.allowUnfree = false;

  # Bootloader systemd-boot (wird von secureboot.nix -> lanzaboote ersetzt)
  boot = {
    loader = {
      systemd-boot = {
        enable       = true;
        editor       = false;          # verhindert Passwort-Bypass
        consoleMode  = "max";
        configurationLimit = 5;         # kleine Platte -> weniger Generationen
      };
      efi.canTouchEfiVariables = true;
      timeout = 5;
    };

    # Hardened Kernel ist mit 26.05 nicht mehr maintained; stattdessen der
    # Standard-Kernel mit Hardened-Optionen (identische Entscheidung wie apphost).
    #kernelPackages = pkgs.linuxPackages_hardened;

    # Kernel-Module für Container-Netzwerk. Müssen beim Boot geladen werden, weil
    # security.lockKernelModules=true (security.nix) späteres Nachladen verbietet.
    # Kata/gVisor-Module (vhost_vsock, kvm_*) bewusst weggelassen – diese DNS-VM
    # betreibt nur einen einzelnen, vertrauenswürdigen Pi-hole-Container.
    kernelModules = [
      "br_netfilter"
      "overlay"
      "nf_conntrack"
      "dm_crypt"
      # seit 26.05 manuell nötig, sonst schlägt "docker compose up" fehl
      # (nftables-Regeln für die Container-Bridge lassen sich nicht erzeugen)
      "nf_nat"
      "iptable_nat"
      "iptable_filter"
      "ip6table_nat"
      "ip6table_filter"
      "xt_nat"
      "xt_MASQUERADE"
      "xt_addrtype"
      "xt_conntrack"
      "xt_multiport"
      "xt_tcpudp"
    ];

    # Ungenutzte/gefährliche Module blacklisten (CIS Benchmark)
    blacklistedKernelModules = [
      # Selten genutzte Netzwerk-Protokolle
      "dccp" "sctp" "rds" "tipc" "n-hdlc" "ax25" "netrom" "x25" "atm"
      "ieee802154" "rose" "econet" "af_802154" "ipx" "appletalk" "psnap"
      # Seltene Dateisysteme
      "cramfs" "freevxfs" "jffs2" "hfs" "hfsplus" "udf"
      # Netzwerk-Dateisysteme
      "cifs" "nfs" "nfsv3" "nfsv4" "gfs2" "ksmbd"
      # Hardware
      "bluetooth" "btusb"
      "usb-storage" "uas"
      "firewire-core"
    ];

    # Kernel-Parameter – Härtung auf Boot-Ebene
    kernelParams = [
      # KASLR, SMEP, SMAP
      "randomize_va_space=2"
      "pti=on"                         # Page Table Isolation (Meltdown)
      "vsyscall=none"                  # Keine vsyscall-Page
      "debugfs=off"                    # Keine Debug-Informationen

      # volle Spectre/Meltdown Mitigations
      "spec_store_bypass_disable=on"
      "tsx=off"
      "tsx_async_abort=full,nosmt"
      "mds=full,nosmt"
      "l1tf=full,force"
      "retbleed=auto,nosmt"

      # Kernel Lockdown
      "lockdown=confidentiality"
      "module.sig_enforce=1"

      # IOMMU (verhindert DMA-Angriffe)
      "iommu=force"
      "amd_iommu=on"
      "intel_iommu=on"
      "iommu.passthrough=0"

      # Heap-Schutz
      "page_alloc.shuffle=1"
      "page_poison=1"
      "slub_debug=FZP"
      "init_on_alloc=1"
      "init_on_free=1"

      # EFI/PCI
      "efi=disable_early_pci_dma"

      # Auditierung
      "audit=1"
    ];

    # Sysctls
    kernel.sysctl = {
      # Netzwerk-Härtung
      "net.ipv4.conf.all.rp_filter"                   = 1;
      "net.ipv4.conf.default.rp_filter"               = 1;
      "net.ipv4.conf.all.accept_source_route"         = 0;
      "net.ipv4.conf.default.accept_source_route"     = 0;
      "net.ipv6.conf.all.accept_source_route"         = 0;
      "net.ipv4.conf.all.send_redirects"              = 0;
      "net.ipv4.conf.default.send_redirects"          = 0;
      "net.ipv4.conf.all.accept_redirects"            = 0;
      "net.ipv4.conf.default.accept_redirects"        = 0;
      "net.ipv4.conf.all.secure_redirects"            = 0;
      "net.ipv4.conf.default.secure_redirects"        = 0;
      "net.ipv6.conf.all.accept_redirects"            = 0;
      "net.ipv6.conf.default.accept_redirects"        = 0;
      "net.ipv4.conf.all.log_martians"                = 1;
      "net.ipv4.conf.default.log_martians"            = 1;
      "net.ipv4.icmp_echo_ignore_broadcasts"          = 1;
      "net.ipv4.icmp_ignore_bogus_error_responses"    = 1;
      "net.ipv4.tcp_syncookies"                       = 1;
      "net.ipv4.tcp_rfc1337"                          = 1;
      "net.ipv4.tcp_timestamps"                       = 0;   # Verhindert Uptime-Fingerprinting
      "net.ipv4.tcp_fin_timeout"                      = 15;
      "net.ipv4.tcp_max_syn_backlog"                  = 4096;
      "net.ipv4.tcp_syn_retries"                      = 2;
      "net.ipv4.tcp_synack_retries"                   = 2;
      "net.core.bpf_jit_harden"                       = 2;
      "net.ipv4.conf.all.arp_ignore"                  = 1;
      "net.ipv4.conf.all.arp_announce"                = 2;

      # IPv6 Härtung
      "net.ipv6.conf.all.accept_ra"                   = 0;
      "net.ipv6.conf.default.accept_ra"               = 0;
      "net.ipv6.conf.all.autoconf"                    = 0;
      "net.ipv6.conf.default.autoconf"                = 0;

      # Container-Networking aktivieren (Docker-Bridge -> Pi-hole-Container)
      "net.ipv4.ip_forward"                           = 1;
      "net.bridge.bridge-nf-call-iptables"            = 1;
      "net.bridge.bridge-nf-call-ip6tables"           = 1;

      # Kernel/Memory-Härtung
      "kernel.kptr_restrict"             = 2;
      "kernel.dmesg_restrict"            = 1;
      "kernel.unprivileged_bpf_disabled" = 1;
      "net.core.bpf_jit_enable"          = 0;
      "kernel.perf_event_paranoid"       = 3;
      "kernel.randomize_va_space"        = 2;
      "vm.mmap_rnd_bits"                 = 32;
      "vm.mmap_rnd_compat_bits"          = 16;
      "kernel.yama.ptrace_scope"         = 2;
      "kernel.sysrq"                     = 0;
      "fs.suid_dumpable"                 = 0;
      "fs.protected_hardlinks"           = 1;
      "fs.protected_symlinks"            = 1;
      "fs.protected_fifos"               = 2;
      "fs.protected_regular"             = 2;
      "vm.swappiness"                    = 10;
      "kernel.pid_max"                   = 65536;
      "kernel.unprivileged_userns_clone" = 1;      # Docker userns-remap

      # Puffer für Docker-Netzwerk
      "net.core.rmem_max" = 16777216;
      "net.core.wmem_max" = 16777216;
    };
  };

  # Locale & Zeitzone
  i18n = {
    defaultLocale  = "de_DE.UTF-8";
    supportedLocales = [ "de_DE.UTF-8/UTF-8" "en_US.UTF-8/UTF-8" ];
  };
  time.timeZone = "Europe/Berlin";

  # Benutzer immutable, kein mutableUsers
  users = {
    mutableUsers = false;

    users = {
      # Haupt-Administratorkonto
      pihole = {
        isNormalUser    = true;
        home            = "/home/pihole";
        createHome      = true;
        extraGroups     = [ "docker" "systemd-journal" "wheel" ];
        shell           = pkgs.bash;
        openssh.authorizedKeys.keys = import ./ssh-key.nix;
        hashedPasswordFile = "/etc/pihole-password-hash";
      };

      # Kein Root-Login über SSH (PermitRootLogin = "no", s.u.). Aber ein Passwort
      # für die LOKALE Konsole (Proxmox-Konsole) – sonst ist der Emergency-/
      # Rescue-Modus nicht nutzbar: mit gesperrtem root (`!`) verweigert sulogin
      # den Zugang und man kann einen Boot-Fehler nicht mehr debuggen.
      # Passwort = dasselbe wie beim Nutzer 'pihole' (install.sh schreibt den Hash).
      root = {
        hashedPasswordFile = "/etc/pihole-password-hash";
        openssh.authorizedKeys.keys = [];
      };
    };

    # Docker-Gruppe
    groups.docker = {};
  };

  # System-Pakete – schlank, aber DNS-tauglich
  environment.systemPackages = with pkgs; [
    # Basis-Tools
    vim nano curl wget git htop
    tmux unzip
    lsof tcpdump
    jq

    # Pflicht auf einem DNS-Server (dig/nslookup, u.a. für scripts/verify-dns.sh)
    dnsutils

    # Sicherheits-Tools
    apparmor-utils
    audit
    lynis           # Security-Audit
    aide            # File-Integrity-Monitoring

    # Container-Tools
    docker-compose
    skopeo          # Image-Digests pinnen

    # Kryptographie
    gnupg
    age
    openssl

    # Netzwerk
    iptables
    nftables
    iproute2
    bridge-utils
  ];

  # Shell-Aliase – dieselbe Bedienung wie apphost (pull/update/rebuild/up/down/…),
  # angepasst auf /opt/pihole und den einzelnen Pi-hole-Container.
  environment.shellAliases = {
    # Updates aus dem lokalen Repo holen (siehe install.sh: /opt/pihole).
    # Ohne sudo: /opt/pihole gehört dem User 'pihole' – sudo würde git als root
    # ausführen und "detected dubious ownership" auslösen.
    pull = "cd /opt/pihole && git pull";

    # NixOS rebuilden
    rebuild      = "sudo nixos-rebuild switch --flake path:/opt/pihole#pihole";
    rebuild-boot = "sudo nixos-rebuild boot   --flake path:/opt/pihole#pihole";

    # Updates holen, Flake-Inputs aktualisieren + sofort rebuilden
    update = "pull && cd /opt/pihole && nix flake update && sudo nixos-rebuild switch --flake path:/opt/pihole#pihole";

    # Nix-Store aufräumen
    gc = "sudo nix-collect-garbage --delete-older-than 30d && sudo nix store optimise";

    # Pi-hole-Container
    up      = "cd /opt/pihole && docker compose up -d";
    down    = "cd /opt/pihole && docker compose down";
    restart = "cd /opt/pihole && docker compose restart";
    logs    = "cd /opt/pihole && docker compose logs -f";

    # Pi-hole-Image aktualisieren (neues Digest -> ziehen + neu starten)
    pihole-update = "cd /opt/pihole && docker compose pull && docker compose up -d";

    # Pi-hole-CLI im Container (z.B. 'pihole status', 'pihole -t')
    pihole = "docker exec -it pihole pihole";

    # Schnellstatus
    status = "systemctl status --no-pager docker && docker ps";

    # Wildcard-DNS verifizieren (*.apphost.lan -> App-Host-VM)
    verify = "bash /opt/pihole/scripts/verify-dns.sh";

    # Kuratierte Blocklisten setzen + Gravity aktualisieren
    seed-lists = "bash /opt/pihole/scripts/seed-adlists.sh";
  };

  # SSH – maximale Härtung (identisch zum apphost-Repo)
  services.openssh = {
    enable = true;
    openFirewall = false;  # Firewall manuell verwaltet (networking.nix)

    settings = {
      # Authentifizierung
      PermitRootLogin              = "no";
      PasswordAuthentication       = false;
      KbdInteractiveAuthentication = false;
      PubkeyAuthentication         = true;

      # Sitzungs-Härtung
      X11Forwarding                = false;
      AllowTcpForwarding           = "no";
      AllowAgentForwarding         = false;
      PermitTunnel                 = "no";
      PermitUserEnvironment        = false;
      MaxAuthTries                 = 3;
      MaxSessions                  = 3;
      LoginGraceTime               = 30;
      ClientAliveInterval          = 300;
      ClientAliveCountMax          = 2;
      TCPKeepAlive                 = false;

      # Nur starke Algorithmen
      Ciphers = [
        "chacha20-poly1305@openssh.com"
        "aes256-gcm@openssh.com"
        "aes128-gcm@openssh.com"
      ];
      KexAlgorithms = [
        "mlkem768x25519-sha256"               # PQ-hybrid
        "sntrup761x25519-sha512@openssh.com"  # PQ-hybrid
        "curve25519-sha256"
        "curve25519-sha256@libssh.org"
        "diffie-hellman-group16-sha512"
        "diffie-hellman-group18-sha512"
      ];
      Macs = [
        "hmac-sha2-512-etm@openssh.com"
        "hmac-sha2-256-etm@openssh.com"
      ];

      # Banner
      Banner = "/etc/ssh/banner.txt";
    };

    hostKeys = [
      { type = "ed25519"; path = "/etc/ssh/ssh_host_ed25519_key"; }
      { type = "rsa"; bits = 4096; path = "/etc/ssh/ssh_host_rsa_key"; }
    ];
  };

  # SSH-Banner (rechtliche Absicherung)
  environment.etc."ssh/banner.txt".text = ''
    ╔══════════════════════════════════════════════════════════════╗
    ║         AUTORISIERTER ZUGRIFF IST AUSSCHLIESSLICH            ║
    ║         FÜR BERECHTIGTE BENUTZER GESTATTET.                  ║
    ║         Alle Aktivitäten werden protokolliert.               ║
    ╚══════════════════════════════════════════════════════════════╝
  '';

  # Automatische Updates (flake-basiert, zieht vom lokalen Repository /opt/pihole)
  system.autoUpgrade = {
    enable        = true;
    flake         = "/opt/pihole";
    allowReboot   = false;            # Manueller Reboot nach Kernel-Updates
    dates         = "04:30";
    flags         = [ "--no-build-output" ];
    randomizedDelaySec = "15min";
  };

  # Journal mit persistenten Logs. Auf der kleinen Platte kleineres Limit als apphost.
  services.journald.extraConfig = ''
    Storage=persistent
    Compress=yes
    SystemMaxUse=1G
    SystemKeepFree=2G
    MaxRetentionSec=3months
    ForwardToSyslog=no
    Audit=yes
  '';

  # Nix-Daemon Härtung & GC
  nix = {
    gc = {
      automatic = true;
      dates     = "weekly";
      options   = "--delete-older-than 30d";
    };

    settings = {
      auto-optimise-store      = true;
      experimental-features    = [ "nix-command" "flakes" ];
      allowed-users            = [ "@wheel" "pihole" ];
      trusted-users            = [ "root" ];
      sandbox                  = true;
      max-jobs                 = "auto";
      cores                    = 0;
      substituters             = [ "https://cache.nixos.org" ];
      trusted-public-keys      = [
        "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      ];
    };
  };

  # Chrony (Network Time Secure / NTS via TLS) – identisch zu apphost
  services.chrony = {
    enable = true;
    servers = [];  # NTS-Server in extraConfig
    extraConfig = ''
      server time.cloudflare.com iburst nts
      server nts.netnod.se iburst nts
      server ptbtime1.ptb.de iburst nts

      ntsdumpdir /var/lib/chrony

      makestep 1.0 3
      maxdistance 1.5
      leapsecmode slew
      maxslewrate 1000
      authselectmode require
    '';
  };
  services.timesyncd.enable = false;

  # DNS muss vor chrony verfügbar sein (sonst scheitert initstepslew)
  systemd.services.chronyd.after = [
    "network-online.target"
    "nss-lookup.target"
  ];
  systemd.services.chronyd.wants = [ "network-online.target" ];

  # PAM – Login-Limits
  security.pam = {
    loginLimits = [
      { domain = "*"; type = "hard"; item = "core";    value = "0";     }
      { domain = "*"; type = "hard"; item = "nofile";  value = "65536"; }
      { domain = "*"; type = "soft"; item = "nofile";  value = "32768"; }
    ];
  };
}
