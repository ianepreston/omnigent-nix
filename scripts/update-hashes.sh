#!/usr/bin/env bash
# Regenerate the fixed-output hashes in nix/source.nix after changing `version`
# there. Run on any Linux machine with Nix (CI runs it on Renovate PRs, see
# .github/workflows/renovate-hashes.yml):
#
#   scripts/update-hashes.sh
#
# 1. Regenerates the upstream source hash.
# 2. Re-syncs the pins copied from that source's lockfiles (`commit`, pnpm
#    version, celPython, pythonPins) with scripts/sync-upstream-pins.py.
# 3. Regenerates the pnpm tarball hash and the pnpm dependency-store hash.
#
# Each hash is blanked, the narrowest derivation that consumes it is built, and
# the hash Nix reports is written back. Steps run in dependency order so that
# exactly one fixed-output derivation is stale at a time and the reported
# mismatch is unambiguous.
set -euo pipefail
cd "$(dirname "$0")/.."

file=nix/source.nix
blank="sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
system=$(nix eval --impure --raw --expr builtins.currentSystem)

blank_hash() { # <perl pattern anchoring the hash line>
  perl -0pi -e "s|($1\\s*=\\s*\")sha256-[A-Za-z0-9+/]+=*(\")|\${1}${blank}\${2}| or die qq(no hash matches: \Q$1\E\\n)" "$file"
}

regen() { # <attr to build> <perl pattern anchoring the hash line>
  local attr=$1 pattern=$2 got
  blank_hash "$pattern"
  # The build is expected to fail with a hash mismatch; that is the point.
  got=$(nix build "path:$PWD#packages.$system.$attr" --no-link 2>&1 | sed -n 's/^ *got: *//p' | head -1 || true)
  [ -n "$got" ] || { echo "no hash mismatch reported for $attr" >&2; exit 1; }
  perl -0pi -e "s|($pattern\\s*=\\s*\")\Q${blank}\E(\")|\${1}${got}\${2}|" "$file"
  echo "$attr: $got"
}

regen omnigent-source 'src\s*=\s*fetchFromGitHub\s*\{[^}]*?\bhash' # upstream source

src=$(nix build "path:$PWD#packages.$system.omnigent-source" --no-link --print-out-paths)
nix run --inputs-from "path:$PWD" nixpkgs#python3 -- -I scripts/sync-upstream-pins.py "$src"

# pnpm is a dependency of the pnpm store. Blank the store hash too: otherwise a
# store path already valid under the old hash (a warm local store) would be
# reused without ever building pnpm, and no mismatch would be reported.
blank_hash 'pnpmDepsHash'
regen omnigent-pnpm-deps '\bpnpm\s*=\s*\{[^}]*?\bhash' # pinned pnpm tarball
regen omnigent-pnpm-deps 'pnpmDepsHash'                # pnpm dependency store
echo "done; review nix/source.nix, then: nix flake check"
