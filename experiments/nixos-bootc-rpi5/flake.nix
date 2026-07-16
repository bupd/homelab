{
  description = "NixOS bootc image for Raspberry Pi 5";

  inputs = {
    nixpkgs.url = "https://channels.nixos.org/nixos-24.11/nixexprs.tar.xz";
    raspberry-pi-nix.url = "git+https://github.com/nix-community/raspberry-pi-nix?ref=master";
  };

  outputs = { self, nixpkgs, raspberry-pi-nix }:
    let
      system = "aarch64-linux";
      nixos = self.nixosConfigurations.rpi5;
      pkgs = import nixpkgs { inherit system; };
    in
    {
      nixosConfigurations.rpi5 = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          raspberry-pi-nix.nixosModules.raspberry-pi
          ./nixos/configuration.nix
        ];
      };

      packages.${system} = {
        toplevel = nixos.config.system.build.toplevel;
        kernel = nixos.config.system.build.kernel;
        initrd = nixos.config.system.build.initialRamdisk;
        rpiFirmware = nixos.pkgs.raspberrypifw;
      };

      formatter.${system} = pkgs.nixpkgs-fmt;
    };
}
