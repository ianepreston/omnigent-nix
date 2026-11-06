# Package set for one nixpkgs instance. Returns everything the flake publishes
# per system; unsupported outputs (desktop off Linux, runner image off Linux)
# are simply absent.
{ pkgs }:
let
  inherit (pkgs) lib;

  upstream = pkgs.callPackage ./source.nix { };

  pnpmDeps = pkgs.fetchPnpmDeps {
    pname = "omnigent-pnpm-deps";
    inherit (upstream) version src;
    pnpmWorkspaces = [
      "web"
      "omnigent-desktop-electron"
    ];
    fetcherVersion = 5;
    hash = upstream.pnpmDepsHash;
  };

  webAssets = pkgs.callPackage ./web-assets.nix { inherit upstream pnpmDeps; };

  omnigent = pkgs.callPackage ./omnigent.nix { inherit upstream webAssets; };

  omnigent-host = pkgs.callPackage ./host.nix { inherit omnigent; };
in
{
  inherit
    omnigent
    omnigent-host
    ;
  omnigent-web-assets = webAssets;
  default = omnigent;
}
// lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
  omnigent-desktop = pkgs.callPackage ./desktop.nix {
    electron = pkgs.electron_45;
    inherit
      omnigent
      upstream
      webAssets
      pnpmDeps
      ;
  };
  omnigent-runner-image = pkgs.callPackage ./runner-image.nix { inherit omnigent-host; };
}
