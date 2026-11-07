#!/usr/bin/env bash
# Prove the fixed-output hashes (upstream source, pnpm dependency store, pinned
# Python sdists) do not depend on the consumer's nixpkgs revision.
#
#   scripts/check-hash-independence.sh [<nixpkgs-rev-or-flake-ref> ...]
#
# Each argument is a nixpkgs revision (40 hex chars) or a full flake reference;
# a consumer's lock can be read with:
#   jq -r '.nodes["nixpkgs-unstable"].locked.rev' /path/to/consumer/flake.lock
# The flake's own locked nixpkgs is always checked first. Every build must
# succeed with the hash recorded in nix/source.nix; a mismatch fails loudly.
#
# A fixed-output derivation whose output path is already in the store is NOT
# re-fetched (Nix addresses it by its declared hash), so a plain build proves
# nothing on a warm store. Each derivation is therefore also built with
# `--rebuild`, which re-runs the fetch with this nixpkgs's tooling and compares
# the result with the declared hash.
set -euo pipefail
cd "$(dirname "$0")/.."

system=$(nix eval --impure --raw --expr builtins.currentSystem)
# Fixed-output derivations only: nothing here depends on nixpkgs beyond the
# fetchers and (for pnpm) the pinned pnpm tool.
attrs=(omnigent-source omnigent-pnpm-deps)
mapfile -t pins < <(nix eval --json "path:$PWD#packages.$system.omnigent.pythonSources" --apply builtins.attrNames | tr -d '[]"' | tr ',' '\n')

check() { # <label> [extra nix args...]
  local label=$1; shift
  for a in "${attrs[@]}"; do
    nix build "path:$PWD#packages.$system.$a" --no-link "$@" >/dev/null
    nix build "path:$PWD#packages.$system.$a" --no-link --rebuild "$@" >/dev/null
    echo "ok  $label  $a (re-fetched, hash matches)"
  done
  # Pinned python sdists (fetchPypi). Installables, not `--expr`, so that
  # --override-input applies.
  local n
  for n in "${pins[@]}"; do
    nix build "path:$PWD#packages.$system.omnigent.pythonSources.$n" --no-link "$@" >/dev/null
    nix build "path:$PWD#packages.$system.omnigent.pythonSources.$n" --no-link --rebuild "$@" >/dev/null
    echo "ok  $label  python sdist $n (re-fetched, hash matches)"
  done
}

check "own-nixpkgs"
for ref in "$@"; do
  case $ref in
    *:* ) full=$ref ;;
    * ) full="github:NixOS/nixpkgs/$ref" ;;
  esac
  check "$ref" --override-input nixpkgs "$full"
done
echo "all fixed-output hashes are independent of the tested nixpkgs revisions"
