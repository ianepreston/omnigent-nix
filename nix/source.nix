# The single upstream release this flake packages. A version bump changes this
# file (tag, source hash, pnpm dependency hash) in one reviewable change;
# `scripts/update-hashes.sh` regenerates the fixed-output hashes and re-syncs
# the pins below that are copied from upstream's lockfiles.
#
# Renovate (renovate.json) rewrites `version` and `commit` together from the
# annotation below; .github/workflows/renovate-hashes.yml then runs
# `scripts/update-hashes.sh` on the PR branch. Keep `commit` within a few lines
# of `version`, or the Renovate match stops spanning both.
{ fetchFromGitHub }:
rec {
  # renovate: datasource=github-tags depName=omnigent-ai/omnigent versioning=pep440
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

  # The exact pnpm upstream pins (`packageManager` in its package.json), fetched
  # from the npm registry. The pnpm used for `fetchPnpmDeps` shapes its output, so
  # taking whatever pnpm the consumer's nixpkgs ships would make the dependency
  # hash below depend on the consumer's nixpkgs revision.
  pnpm = {
    version = "11.15.1";
    hash = "sha256-J0YGKbEBEWBOf5iIJ1O1M5iYaCDCDgoGXzpKXp59tx8=";
  };

  # Dependency store for `web` + `web/electron`, from the upstream pnpm
  # lockfile. Shared by the web UI and desktop derivations.
  pnpmDepsHash = "sha256-IYmNpinF3KWxxnVJtC7Ae+m23kWRE7Y1N6UxY1/D944=";

  # Source-pinned PyPI-only dependencies absent from nixpkgs.
  celPython = {
    version = "0.5.0";
    # sha256 of the py3-none-any wheel, from upstream's uv.lock.
    wheelSha256 = "d0f85008b89655c2bb18d797d2fa3f96f2ed80f4a3b43b0e8138c6646581e5f6";
  };

  # ABI-sensitive Python dependencies pinned to the tagged release's uv.lock
  # (sdist sha256; versions and hashes re-synced by `scripts/update-hashes.sh`). nixpkgs-unstable is newer than upstream's constraints for
  # these (openai <2.45, mcp <2, websockets <15, certifi >=2026.10.19), so they
  # are built from the locked releases instead of relaxing the constraints.
  pythonPins = {
    openai = {
      version = "2.41.0";
      sdistName = "openai";
      sha256 = "db5c362acd6604b84f076abbefa66826ea4b46ecba2954ed866e6a149a1352c0";
    };
    openai-agents = {
      version = "0.13.6";
      sdistName = "openai_agents";
      sha256 = "de7b3add7933ae704a5ee6e531f650d8aabb3ebaa1631f458ba39684a5ed966e";
    };
    mcp = {
      version = "1.30.0";
      sdistName = "mcp";
      sha256 = "445414625fce5c295faa505bb11bacece661ab6f4028d57c935db57820b7a3e4";
    };
    websockets = {
      version = "14.2";
      sdistName = "websockets";
      sha256 = "5059ed9c54945efb321f097084b4c7e52c246f2c869815876a69d1efc4ad6eb5";
    };
    certifi = {
      version = "2026.10.19";
      sdistName = "certifi";
      sha256 = "035c1e85572b141bf1c3a3eff0e33a8eb74917522f2559075ff8d2fea780a1ae";
    };
  };
}
