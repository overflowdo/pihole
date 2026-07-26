{
  description = "Pi-hole – Wildcard-DNS für apphost.lan als gehärtete, deklarative NixOS-VM";

  # Bewusst an das apphost-Repo angelehnt (gleiche nixpkgs-Serie, gleiche
  # disko-/lanzaboote-Inputs), damit beide VMs identisch gebaut & gewartet werden.
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    disko = {
      url    = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    lanzaboote = {
      url    = "github:nix-community/lanzaboote";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, disko, lanzaboote, ... }:
  let
    # Von nixos/install.sh pro Installation generiert (gitignored). Erst nach dem
    # ersten Lauf vorhanden – daher optional eingebunden.
    hwConfig = ./nixos/hardware-configuration.nix;
  in
  {
    nixosConfigurations.pihole = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";

      modules = [
        disko.nixosModules.disko
        lanzaboote.nixosModules.lanzaboote
        ./nixos/disko.nix
        ./nixos/configuration.nix

      ] ++ nixpkgs.lib.optionals (builtins.pathExists hwConfig) [ hwConfig ];
    };
  };
}
