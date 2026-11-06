#!/usr/bin/env bash
# Regenerate the fixed-output hashes in nix/source.nix after changing `version`
# / `commit` there. Run on any Linux machine with Nix:
#
#   scripts/update-hashes.sh
#
# It blanks one hash at a time, builds the derivation that consumes it, and
# writes back the hash Nix reports.
set -euo pipefail
cd "$(dirname "$0")/.."

file=nix/source.nix
blank="sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
system=$(nix eval --impure --raw --expr builtins.currentSystem)

regen() { # <attr to build> <perl pattern anchoring the hash line>
  local attr=$1 pattern=$2 got
  perl -0pi -e "s|($pattern\\s*=\\s*\")sha256-[A-Za-z0-9+/]+=*(\")|\${1}${blank}\${2}|" "$file"
  # The build is expected to fail with a hash mismatch; that is the point.
  got=$(nix build "path:$PWD#packages.$system.$attr" --no-link 2>&1 | sed -n 's/^ *got: *//p' | head -1 || true)
  [ -n "$got" ] || { echo "no hash mismatch reported for $attr" >&2; exit 1; }
  perl -0pi -e "s|($pattern\\s*=\\s*\")\Q${blank}\E(\")|\${1}${got}\${2}|" "$file"
  echo "$attr: $got"
}

regen omnigent-web-assets 'hash'                 # upstream source
regen omnigent-web-assets 'pnpmDepsHash'         # pnpm dependency store
echo "done; review nix/source.nix, then: nix flake check"
