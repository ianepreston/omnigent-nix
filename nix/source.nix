# The single upstream release this flake packages. A version bump changes this
# file (tag, source hash, pnpm dependency hash) in one reviewable change;
# `scripts/update-hashes.sh` regenerates the fixed-output hashes.
{ fetchFromGitHub }:
rec {
  version = "0.21.0";
  tag = "v${version}";
  # Commit the tag points at. Injected into the build metadata instead of
  # running `git rev-parse` (there is no .git in the Nix sandbox).
  commit = "2f636330cc6e28bfe1d22f741eda6db34a192d39";

  src = fetchFromGitHub {
    owner = "omnigent-ai";
    repo = "omnigent";
    inherit tag;
    hash = "sha256-qj1o4K3dQ0bA99ij9MILfb/SUqK+/11kRhLvZM30vuQ=";
  };

  # Dependency store for `web` + `web/electron`, from the upstream pnpm
  # lockfile. Shared by the web UI and desktop derivations.
  pnpmDepsHash = "sha256-m0VbjpVsuOS56BUC+uO2aku7y5s+Oh/tKm9onX/qw6o=";

  # Source-pinned PyPI-only dependencies absent from nixpkgs.
  celPython = {
    version = "0.5.0";
    # sha256 of the py3-none-any wheel, from upstream's uv.lock.
    wheelSha256 = "d0f85008b89655c2bb18d797d2fa3f96f2ed80f4a3b43b0e8138c6646581e5f6";
  };

  # nixpkgs-unstable ships mcp 2.x; omnigent needs the 1.x API it locks.
  mcp = {
    version = "1.30.0";
    sha256 = "445414625fce5c295faa505bb11bacece661ab6f4028d57c935db57820b7a3e4";
  };
}
