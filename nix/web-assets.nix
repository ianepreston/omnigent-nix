# Offline Vite build of the web SPA (served by the server) and the desktop
# shell's overlay pages, from upstream's locked pnpm workspace.
{
  lib,
  stdenv,
  nodejs_22,
  pnpm,
  pnpmConfigHook,
  upstream,
  pnpmDeps,
}:
stdenv.mkDerivation {
  pname = "omnigent-web-assets";
  inherit (upstream) version src;
  inherit pnpmDeps;

  nativeBuildInputs = [
    nodejs_22
    pnpm
    pnpmConfigHook
  ];

  # Only the `web` package is installed and built here.
  pnpmWorkspaces = [ "web" ];

  # Upstream pins `packageManager: pnpm@11.15.1`; never let pnpm try to
  # download "its own" version inside the sandbox.
  env = {
    npm_config_manage_package_manager_versions = "false";
    npm_config_update_notifier = "false";
    CI = "true";
  };

  buildPhase = ''
    runHook preBuild

    pnpm --filter web run build
    pnpm --filter web run build:overlay
    pnpm --filter web run build:server-selector-v2

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out
    cp -r omnigent/server/static/web-ui $out/web-ui
    cp -r web/electron/overlay $out/overlay
    cp -r web/electron/server-selector-v2 $out/server-selector-v2

    runHook postInstall
  '';

  meta = {
    description = "Omnigent web UI bundle (Vite build of the upstream pnpm workspace)";
    license = lib.licenses.asl20;
  };
}
