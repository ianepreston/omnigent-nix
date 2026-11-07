# `omnigent` plus the programs native harnesses expect on PATH. Installing it
# starts nothing: a host executes agent work and must be started explicitly.
{
  lib,
  stdenv,
  callPackage,
  omnigent,
  tmux,
  bubblewrap,
  git,
  codex,
  # Harness executables Nix provides (omnigent's npm-based harness installer is
  # never used). Override to select others: `claude-code`, `opencode`, `goose-cli`.
  harnessPackages ? [ codex ],
  # Additional tools for a consumer's own harnesses or toolchains.
  extraPackages ? [ ],
}:
let
  hostTools = [
    tmux
    git
  ]
  ++ lib.optionals stdenv.hostPlatform.isLinux [ bubblewrap ]
  ++ harnessPackages
  ++ extraPackages;
in
callPackage ./launchers.nix { } {
  pname = "omnigent-host";
  inherit (omnigent) version;
  inherit (omnigent.passthru) pythonEnv;
  pathPackages = hostTools;
  passthru = {
    inherit omnigent hostTools;
  };
  meta = omnigent.meta // {
    description = "Omnigent CLI with host dependencies (tmux, bubblewrap, harness CLIs)";
  };
}
