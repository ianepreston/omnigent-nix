# Electron shell around the server-hosted UI, built from the same source
# revision as the CLI. Runs on nixpkgs' Electron: nothing is downloaded, the
# built-in updater is off, and the CLI path is the co-built Nix runtime.
{
  lib,
  stdenv,
  nodejs_22,
  pnpm,
  pnpmConfigHook,
  electron,
  makeWrapper,
  makeDesktopItem,
  copyDesktopItems,
  omnigent,
  upstream,
  webAssets,
  pnpmDeps,
}:
stdenv.mkDerivation (finalAttrs: {
  pname = "omnigent-desktop";
  inherit (upstream) version src;
  inherit pnpmDeps;

  patches = [
    ./patches/desktop-nix.patch
    # Upstream bug, not Nix-specific: the update overlay can be resized to 0px
    # tall, which aborts Electron on Wayland at launch (GNOME/mutter). Drop
    # once upstream clamps the height itself.
    ./patches/desktop-overlay-min-height.patch
  ];

  nativeBuildInputs = [
    nodejs_22
    pnpm
    pnpmConfigHook
    makeWrapper
    copyDesktopItems
  ];

  pnpmWorkspaces = [ "omnigent-desktop-electron" ];

  env = {
    ELECTRON_SKIP_BINARY_DOWNLOAD = "1";
    npm_config_manage_package_manager_versions = "false";
    CI = "true";
  };

  dontBuild = true;

  # Production dependencies only (no electron / electron-builder / playwright).
  pnpmInstallFlags = [ "--prod" ];

  installPhase = ''
    runHook preInstall

    # Keep upstream's workspace layout so pnpm's relative symlinks stay valid:
    #   lib/omnigent-desktop/node_modules/.pnpm   (virtual store, prod only)
    #   lib/omnigent-desktop/web/electron         (the app)
    root=$out/lib/omnigent-desktop
    app=$root/web/electron
    mkdir -p $app $out/share/icons/hicolor/scalable/apps $root/node_modules

    cp -a node_modules/.pnpm $root/node_modules/.pnpm
    cd web/electron
    for d in src about browser-permission workspace-picker setup arca-connect \
             ssh-connect find return-banner connection-loading reconnect-overlay icons; do
      cp -r "$d" $app/
    done
    cp package.json $app/
    cp -a node_modules $app/node_modules
    cp -r ${webAssets}/overlay $app/overlay
    cp -r ${webAssets}/server-selector-v2 $app/server-selector-v2

    install -Dm644 icons/icon.svg $out/share/icons/hicolor/scalable/apps/omnigent.svg

    makeWrapper ${lib.getExe electron} $out/bin/omnigent-desktop \
      --add-flags "$app" \
      --set OMNIGENT_NIX_CLI ${omnigent}/bin/omnigent \
      --set-default OMNIGENT_MANAGED_BY_NIX 1 \
      --set-default ELECTRON_FORCE_IS_PACKAGED 1

    runHook postInstall
  '';

  desktopItems = [
    (makeDesktopItem {
      name = "omnigent";
      desktopName = "Omnigent";
      comment = "Desktop client for an Omnigent server";
      exec = "omnigent-desktop %U";
      icon = "omnigent";
      categories = [
        "Development"
        "Utility"
      ];
      mimeTypes = [ "x-scheme-handler/omnigent" ];
    })
  ];

  passthru = {
    inherit omnigent electron;
  };

  meta = {
    description = "Omnigent desktop client (Electron shell for the server-hosted web UI)";
    homepage = "https://github.com/omnigent-ai/omnigent";
    license = lib.licenses.asl20;
    mainProgram = "omnigent-desktop";
    platforms = lib.platforms.linux;
  };
})
