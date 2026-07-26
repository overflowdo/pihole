{ config, pkgs, lib, ... }:
{
  # Docker mit userns-remap: der Pi-hole-Container läuft dadurch NIE als echtes
  # root – Container-UID 0 wird auf host-UID 100000+ gemappt (dockremap unten).
  # Das ist derselbe "kein Container als root"-Mechanismus wie im apphost-Repo.
  #
  # Bewusst NICHT übernommen (gegenüber apphost): gVisor (runsc), Kata, containerd
  # und der wöchentliche trivy-Scan. Gründe: (1) gVisor fügt jeder DNS-Anfrage
  # spürbar Latenz hinzu – inakzeptabel für den zentralen Resolver; (2) 1 vCPU /
  # 1 GB RAM; (3) hier läuft nur ein einzelnes, vertrauenswürdiges Image.
  # Aktualität der Images übernimmt Renovate (renovate.json).
  virtualisation.docker = {
    enable    = true;
    autoPrune = {
      enable = true;
      dates  = "weekly";
      flags  = [ "--all" "--volumes" "--filter" "until=720h" ];
    };

    daemon.settings = {
      # Default-Runtime: runc (kompatibel, kein Sandbox-Overhead)
      "default-runtime" = "runc";

      # UID-Remap für garantiert nicht-root Container
      "userns-remap" = "default";

      iptables         = true;
      ip6tables        = true;
      "ip-forward"     = true;
      "userland-proxy" = false;  # Direktes nftables/iptables-DNAT statt Userland-Proxy

      # Sauberes Logging mit Rotation & Kompression
      "log-driver" = "json-file";
      "log-opts" = {
        "max-size" = "10m";
        "max-file" = "5";
        "compress" = "true";
      };

      # Zugriff nur via Unix-Socket (keine TCP-Ports exposen)
      hosts = [ "unix:///var/run/docker.sock" ];
    };
  };

  # dockremap: UID/GID 100000–165536 für das rootless Remapping.
  # (Identisch zum apphost-Repo – ohne diesen User funktioniert userns-remap nicht.)
  users.users.dockremap = {
    isSystemUser = true;
    group        = "dockremap";
    subUidRanges = [{ startUid = 100000; count = 65536; }];
    subGidRanges = [{ startGid = 100000; count = 65536; }];
  };
  users.groups.dockremap = {};

  # Resource-Limits für den Docker-Daemon selbst
  systemd.services.docker.serviceConfig = {
    LimitNOFILE = 1048576;
    LimitNPROC  = "infinity";
    LimitCORE   = 0;
  };

  # Docker-Socket nur für die docker-Gruppe zugänglich
  systemd.tmpfiles.rules = [
    "d /run/docker 0750 root docker -"
  ];

  # seccomp-Default-Profil für Docker bereitstellen
  environment.etc."docker/seccomp-default.json".source =
    "${pkgs.docker}/etc/docker/seccomp-default.json";
}
