{
  description = "Omnigent (server, host, desktop) packaged for Nix, with NixOS and Home Manager modules";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    # Used only by `checks` to evaluate the Home Manager module.
    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      home-manager,
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
        "x86_64-darwin"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);
      pkgsFor = system: import nixpkgs { inherit system; };
      packagesFor = system: import ./nix/packages.nix { pkgs = pkgsFor system; };
    in
    {
      packages = forAllSystems (
        system:
        let
          p = packagesFor system;
        in
        # The runner image is a Linux OCI image; it is not a general "package".
        p
      );

      apps = forAllSystems (system: {
        omnigent = {
          type = "app";
          program = "${self.packages.${system}.omnigent}/bin/omnigent";
          meta.description = "Omnigent CLI";
        };
        omnigent-host = {
          type = "app";
          program = "${self.packages.${system}.omnigent-host}/bin/omnigent";
          meta.description = "Omnigent CLI with host dependencies on PATH";
        };
      });

      nixosModules = {
        default = self.nixosModules.omnigent;
        omnigent = import ./modules/nixos/omnigent.nix { inherit self; };
        caddy = import ./modules/nixos/caddy.nix;
        postgresql = import ./modules/nixos/postgresql.nix;
      };

      homeManagerModules = {
        default = self.homeManagerModules.omnigent;
        omnigent = import ./modules/home-manager/omnigent.nix { inherit self; };
      };

      # Lets consumers write `pkgs.omnigent` if they want a overlay.
      overlays.default = final: _prev: {
        inherit (self.packages.${final.stdenv.hostPlatform.system}) omnigent omnigent-host;
      };

      checks = forAllSystems (
        system:
        import ./nix/checks.nix {
          inherit
            self
            system
            nixpkgs
            home-manager
            ;
        }
      );

      formatter = forAllSystems (system: (pkgsFor system).nixfmt);
    };
}
