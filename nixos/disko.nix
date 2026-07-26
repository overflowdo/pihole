# GPT + EFI + zufällig-verschlüsselter Swap + Btrfs
# Root-Partition optional zusätzlich LUKS2-verschlüsselt, siehe disk-encryption.nix
# (identische Struktur wie im apphost-Repo).
#
# Subvolume-Struktur:
#   /    -> root – System
#   /nix -> nix  – Nix Store
#   /var -> var  – Logs, Container-State (Docker)
#   /opt -> opt  – Pi-hole-Repo (/opt/pihole, per git pull aktualisierbar)
#   /tmp -> tmp  – Temporäre Dateien (nosuid,nodev,noexec)
{ ... }:
let
  # Optionale Festplattenverschlüsselung, standardmäßig aus (siehe disk-encryption.nix).
  diskEncryption = import ./disk-encryption.nix;

  rootFilesystem = {
    type      = "btrfs";
    extraArgs = [ "-f" "--label" "nixos" ];

    subvolumes = {

      # System-Root
      "/root" = {
        mountpoint   = "/";
        mountOptions = [ "compress=zstd" "noatime" ];
      };

      # Nix Store
      "/nix" = {
        mountpoint   = "/nix";
        mountOptions = [ "compress=zstd" "noatime" ];
      };

      # Systemdaten (Docker-State, Logs)
      "/var" = {
        mountpoint   = "/var";
        mountOptions = [ "compress=zstd" "noatime" ];
      };

      # Pi-hole-Repo & -Daten
      "/opt" = {
        mountpoint   = "/opt";
        mountOptions = [ "compress=zstd" "noatime" ];
      };

      # Temporäre Dateien nicht ausführbar (Sicherheit)
      "/tmp" = {
        mountpoint   = "/tmp";
        mountOptions = [
          "compress=zstd" "noatime"
          "nosuid" "nodev" "noexec"
        ];
      };
    };
  };

  # Bei aktivierter Verschlüsselung wird Btrfs in einen LUKS2-Container gelegt.
  # Ohne settings.keyFile/passwordFile fragt disko die Passphrase bei der
  # Formatierung interaktiv ab, und systemd fragt sie danach bei jedem Boot
  # erneut über die Konsole ab.
  rootContent =
    if diskEncryption then {
      type    = "luks";
      name    = "cryptroot";
      settings.allowDiscards = true; # TRIM-Unterstützung für SSDs
      content = rootFilesystem;
    } else rootFilesystem;
in
{
  disko.devices = {
    disk = {
      main = {
        type   = "disk";
        device = "/dev/sda"; # Proxmox mit VirtIO-SCSI: bleibt stabil /dev/sda

        content = {
          type = "gpt";
          partitions = {

            # EFI System Partition (Secure Boot / lanzaboote)
            ESP = {
              size    = "512M";
              type    = "EF00";   # EFI System Partition
              content = {
                type         = "filesystem";
                format       = "vfat";
                mountpoint   = "/boot";
                mountOptions = [ "defaults" "umask=0077" "noatime" ];
              };
            };

            # Swap verschlüsselt. 2 GB reichen für die 1-GB-RAM-DNS-VM
            # (apphost nutzt 8 GB – hier bewusst kleiner wegen kleiner Platte).
            swap = {
              size    = "2G";
              content = {
                type             = "swap";
                randomEncryption = true;
              };
            };

            # Root-Partition via Btrfs mit Subvolumes
            root = {
              size    = "100%";
              content = rootContent;
            };
          };
        };
      };
    };
  };
}
