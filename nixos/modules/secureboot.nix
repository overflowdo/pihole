# lanzaboote ersetzt systemd-boot als EFI-Stub und signiert automatisch jede
# NixOS-Generation beim Build. Ohne gültige Signatur kein Boot, sobald der Key
# enrollt ist. Identisch zum apphost-Repo.
{ pkgs, lib, ... }:
{
  boot.loader.systemd-boot.enable = lib.mkForce false;

  boot.lanzaboote = {
    enable    = true;
    pkiBundle = "/etc/secureboot";
  };
  environment.systemPackages = [ pkgs.sbctl ];
}
