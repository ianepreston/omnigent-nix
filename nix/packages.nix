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
    # The desktop targets upstream's Electron major (45). Older nixpkgs (for
    # example nixos-26.05) have no electron_45: fail with an actionable message.
    electron =
      pkgs.electron_45 or (throw ''
        omnigent-nix: the supplied nixpkgs has no `electron_45` (needs nixos-unstable or newer).
        Leave this flake's own nixpkgs input alone, or point it at an unstable nixpkgs, e.g.
          inputs.omnigent.inputs.nixpkgs.follows = "nixpkgs-unstable";
      '');
    inherit
      omnigent
      upstream
      webAssets
      pnpmDeps
      ;
  };
  omnigent-runner-image = pkgs.callPackage ./runner-image.nix { inherit omnigent-host; };
}
