# Entry-point launchers for an Omnigent Python environment.
#
# These are plain scripts whose interpreter is the closure-aware
# `withPackages` environment, so `sys.executable` — which Omnigent uses to
# respawn hosts, runners and git helpers (`-P`, and `-I`, which ignores
# PYTHONPATH) — can import everything, with no environment leakage into the
# agent subprocesses the host launches.
{
  lib,
  stdenvNoCC,
  writeText,
}:
{
  pname,
  version,
  pythonEnv,
  # Path to the upstream server entrypoint script, or null.
  serverEntrypoint ? null,
  # Directories' packages whose bin/ is prefixed onto PATH at start.
  pathPackages ? [ ],
  passthru ? { },
  meta ? { },
}:
let
  header = ''
    #!${pythonEnv}/bin/python3
    import os
    import sys

    # A Nix install is updated through the flake lock, never in place.
    os.environ.setdefault("OMNIGENT_MANAGED_BY_NIX", "1")
    os.environ.setdefault("OMNIGENT_NO_UPDATE_CHECK", "1")
    ${lib.optionalString (
      pathPackages != [ ]
    ) ''os.environ["PATH"] = "${lib.makeBinPath pathPackages}:" + os.environ.get("PATH", "")''}
  '';
  cli = ''
    ${header}
    from omnigent.cli import main

    if __name__ == "__main__":
        sys.exit(main())
  '';
  server = ''
    ${header}
    import runpy

    runpy.run_path("${serverEntrypoint}", run_name="__main__")
  '';
  cliScript = writeText "omnigent-cli" cli;
  serverScript = writeText "omnigent-server" server;
in
stdenvNoCC.mkDerivation {
  inherit pname version;
  dontUnpack = true;
  dontBuild = true;
  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    for name in omnigent omni; do
      cp ${cliScript} $out/bin/$name
    done
    ${lib.optionalString (serverEntrypoint != null) ''
      cp ${serverScript} $out/bin/omnigent-server
    ''}
    chmod 0555 $out/bin/*
    runHook postInstall
  '';
  passthru = passthru // {
    inherit pythonEnv;
  };
  inherit meta;
}
