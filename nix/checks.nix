# `nix flake check` gate: module evaluation (including the validations that
# must refuse to evaluate), then runtime smoke tests of the built packages.
{
  self,
  system,
  nixpkgs,
  home-manager,
}:
let
  pkgs = import nixpkgs { inherit system; };
  inherit (pkgs) lib;
  isLinux = pkgs.stdenv.hostPlatform.isLinux;
  p = self.packages.${system};

  # Evaluating a derivation path is the check; nothing is built.
  evalOnly =
    name: drv:
    pkgs.runCommand "eval-${name}" { } ''
      echo ${builtins.unsafeDiscardOutputDependency drv.drvPath} > $out
    '';

  nixos =
    extra:
    nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        self.nixosModules.omnigent
        (_: {
          boot.loader.grub.enable = false;
          fileSystems."/" = {
            device = "none";
            fsType = "tmpfs";
          };
          system.stateVersion = "26.05";
        })
        extra
      ];
    };

  mustFail =
    name: sys:
    let
      r = builtins.tryEval (builtins.seq sys.config.system.build.toplevel.drvPath true);
    in
    pkgs.runCommand "refuses-${name}" { } (
      if r.success then
        "echo 'configuration evaluated but should have been rejected' >&2; exit 1"
      else
        "touch $out"
    );

  assertEval =
    name: cond: msg:
    pkgs.runCommand "assert-${name}" { } (
      if cond then "touch $out" else "echo ${lib.escapeShellArg msg} >&2; exit 1"
    );

  sqliteLoopback = nixos {
    services.omnigent = {
      enable = true;
      database.sqlite.enable = true;
    };
  };
  uriFileServer = nixos {
    services.omnigent = {
      enable = true;
      publicUrl = "https://omnigent.example.net";
      environmentFile = "/run/secrets/omnigent.env";
      database.uriFile = "/run/secrets/omnigent-database-uri";
    };
  };
  withAdapters = nixos {
    imports = [
      self.nixosModules.caddy
      self.nixosModules.postgresql
    ];
    services.postgresql.enable = true;
    services.caddy.enable = true;
    services.omnigent = {
      enable = true;
      publicUrl = "https://omnigent.example.net";
      caddy = {
        enable = true;
        hostName = "omnigent.example.net";
      };
      postgresql.createLocally = true;
    };
  };

  svc = sys: sys.config.systemd.services.omnigent;

  hm =
    extra:
    home-manager.lib.homeManagerConfiguration {
      pkgs = import nixpkgs { inherit system; };
      modules = [
        self.homeManagerModules.omnigent
        (_: {
          home.username = "tester";
          home.homeDirectory = if isLinux then "/home/tester" else "/Users/tester";
          home.stateVersion = "26.05";
        })
        extra
      ];
    };
  hmHost = hm {
    programs.omnigent.host = {
      enable = true;
      serverUrl = "https://omnigent.example.net";
      autoStart = true;
    };
  };
  hmIdle = hm {
    programs.omnigent.host = {
      enable = true;
      serverUrl = "https://omnigent.example.net";
    };
  };

  moduleChecks = lib.optionalAttrs isLinux {
    nixos-module-sqlite = evalOnly "nixos-module-sqlite" sqliteLoopback.config.system.build.toplevel;
    nixos-module-uri-file = evalOnly "nixos-module-uri-file" uriFileServer.config.system.build.toplevel;
    nixos-module-adapters = evalOnly "nixos-module-adapters" withAdapters.config.system.build.toplevel;

    refuses-exposed-without-auth = mustFail "exposed-without-auth" (nixos {
      services.omnigent = {
        enable = true;
        listen.address = "0.0.0.0";
        database.sqlite.enable = true;
      };
    });
    refuses-no-database = mustFail "no-database" (nixos {
      services.omnigent.enable = true;
    });
    refuses-two-databases = mustFail "two-databases" (nixos {
      services.omnigent = {
        enable = true;
        database = {
          sqlite.enable = true;
          uriFile = "/run/secrets/x";
        };
      };
    });
    refuses-mismatched-caddy-host = mustFail "mismatched-caddy-host" (nixos {
      imports = [ self.nixosModules.caddy ];
      services.omnigent = {
        enable = true;
        database.sqlite.enable = true;
        publicUrl = "https://a.example.net";
        caddy = {
          enable = true;
          hostName = "b.example.net";
        };
      };
    });

    # Secrets never reach the unit: the URI file is a credential, the secrets
    # file an EnvironmentFile, and there is no DATABASE_URL in Environment=.
    secrets-stay-out-of-unit =
      let
        u = svc uriFileServer;
      in
      assertEval "secrets-stay-out-of-unit" (
        !(u.environment ? DATABASE_URL)
        && u.serviceConfig.LoadCredential == [ "database-uri:/run/secrets/omnigent-database-uri" ]
        && u.serviceConfig.EnvironmentFile == [ "/run/secrets/omnigent.env" ]
        && u.serviceConfig.DynamicUser
        && u.environment.HOST == "127.0.0.1"
      ) "unit leaks a secret or loses its hardening/loopback default";

    # The core module owns no proxy or database service.
    core-module-is-standalone = assertEval "core-module-is-standalone" (
      !sqliteLoopback.config.services.caddy.enable && !sqliteLoopback.config.services.postgresql.enable
    ) "core module enabled Caddy or PostgreSQL";

    adapter-wires-caddy-and-postgres = assertEval "adapter-wires-caddy-and-postgres" (
      withAdapters.config.services.caddy.virtualHosts ? "omnigent.example.net"
      && withAdapters.config.services.postgresql.ensureDatabases == [ "omnigent" ]
      && (svc withAdapters).serviceConfig.User == "omnigent"
    ) "adapters did not produce the expected Caddy vhost / database / fixed user";
  };

  hmChecks = {
    hm-module-host = evalOnly "hm-module-host" hmHost.activationPackage;
    hm-module-idle = evalOnly "hm-module-idle" hmIdle.activationPackage;
    refuses-autostart-without-url = mustFailHm;
    # A host is never started merely because the package is installed.
    hm-host-not-started-by-default = assertEval "hm-host-not-started-by-default" (
      !(hmIdle.config.systemd.user.services ? omnigent-host)
    ) "host service defined without autoStart";
  }
  // lib.optionalAttrs isLinux {
    hm-host-autostart-defined = assertEval "hm-host-autostart-defined" (
      hmHost.config.systemd.user.services ? omnigent-host
    ) "autoStart did not define the user service";
  };
  mustFailHm =
    let
      cfg = hm {
        programs.omnigent.host = {
          enable = true;
          autoStart = true;
        };
      };
      r = builtins.tryEval (builtins.seq cfg.activationPackage.drvPath true);
    in
    pkgs.runCommand "refuses-autostart-without-url" { } (
      if r.success then "echo 'autoStart without serverUrl evaluated' >&2; exit 1" else "touch $out"
    );

  # ---- runtime checks (Linux only: they run the built packages) ----

  runtimeChecks = lib.optionalAttrs isLinux {
    pkg-omnigent = p.omnigent;
    pkg-omnigent-host = p.omnigent-host;

    cli-smoke =
      pkgs.runCommand "omnigent-cli-smoke"
        {
          nativeBuildInputs = [ p.omnigent ];
        }
        ''
          export HOME=$TMPDIR
          omnigent --version | tee version.txt
          grep -q '${p.omnigent.version}' version.txt
          omni --version >/dev/null

          # Deterministic build metadata: epoch from SOURCE_DATE_EPOCH, pinned commit.
          grep -q '2f636330' version.txt
          grep -q 'built 1980-01-02' version.txt

          # The self-updater must refuse and point at the flake.
          if omnigent upgrade --check 2> upgrade.err; then
            echo "omni upgrade must fail on a Nix install" >&2; exit 1
          fi
          grep -q 'managed by Nix' upgrade.err
          if OMNIGENT_MANAGED_BY_NIX= omnigent upgrade --check 2>/dev/null; then :; fi

          # The update-check nag is off.
          test "$(env | grep -c '^OMNIGENT_NO_UPDATE_CHECK=')" = 0   # not exported in the build env
          touch $out
        '';

    # Omnigent respawns itself with `sys.executable -P ...` and runs git helpers
    # with `sys.executable -I`, which ignores PYTHONPATH. The interpreter itself
    # must therefore see the whole closure, from a clean environment.
    child-interpreter = pkgs.runCommand "omnigent-child-interpreter" { } ''
      py=$(head -1 ${p.omnigent}/bin/omnigent | sed 's/^#!//')
      cat > probe.py <<'EOF'
      import subprocess, sys
      mods = "omnigent, omnigent.cli, omnigent_client, omnigent_ui_sdk, celpy, psycopg, uvicorn"
      for flags in (["-P"], ["-I"], ["-I", "-s"]):
          r = subprocess.run([sys.executable, *flags, "-c", f"import {mods}"], capture_output=True, text=True)
          if r.returncode != 0:
              sys.exit(f"{flags}: {r.stderr}")
      print("ok:", sys.executable)
      EOF
      env -i "$py" probe.py
      touch $out
    '';

    # omnigent-client imports omnigent at runtime, so the metadata back-edge
    # we removed is only valid inside this single closure.
    client-needs-omnigent = pkgs.runCommand "omnigent-client-needs-omnigent" { } ''
      grep -rq 'from omnigent\.' ${p.omnigent.passthru.omnigent-client}/${pkgs.python3.sitePackages}/omnigent_client/
      touch $out
    '';

    server-smoke =
      pkgs.runCommand "omnigent-server-smoke"
        {
          nativeBuildInputs = [
            p.omnigent
            pkgs.curl
          ];
        }
        ''
          export HOME=$TMPDIR
          port=18769
          HOST=127.0.0.1 PORT=$port ARTIFACT_DIR=$TMPDIR/artifacts \
            DATABASE_URL=sqlite:///$TMPDIR/omnigent.db OMNIGENT_AUTH_PROVIDER=accounts \
            omnigent-server > server.log 2>&1 &
          pid=$!
          trap 'kill $pid 2>/dev/null || true' EXIT

          up=
          for _ in $(seq 1 60); do
            if curl -sf http://127.0.0.1:$port/health -o health.json; then up=1; break; fi
            kill -0 $pid 2>/dev/null || { cat server.log; exit 1; }
            sleep 1
          done
          [ -n "$up" ] || { cat server.log; echo "server never became healthy" >&2; exit 1; }
          grep -q '"status":"ok"' health.json

          # The web UI is bundled and served, not the API-only landing page.
          curl -sf http://127.0.0.1:$port/ -o index.html
          grep -qi '<!doctype html' index.html
          asset=$(grep -o '/assets/[^"]*\.js' index.html | head -1)
          test -n "$asset"
          curl -sf "http://127.0.0.1:$port$asset" -o /dev/null
          touch $out
        '';

    web-ui-bundled = pkgs.runCommand "omnigent-web-ui-bundled" { } ''
      d=${p.omnigent.passthru.omnigent-lib}/${pkgs.python3.sitePackages}/omnigent/server/static/web-ui
      test -f $d/index.html
      ls $d/assets | grep -q '\.js$'
      touch $out
    '';

    # The host wrapper provides tmux/bubblewrap/codex; nothing starts a daemon.
    host-wrapper =
      pkgs.runCommand "omnigent-host-wrapper"
        {
          nativeBuildInputs = [ p.omnigent-host ];
        }
        ''
          export HOME=$TMPDIR
          omnigent --version >/dev/null
          grep -q 'bubblewrap' ${p.omnigent-host}/bin/omnigent
          grep -q 'tmux' ${p.omnigent-host}/bin/omnigent
          grep -q 'codex' ${p.omnigent-host}/bin/omnigent
          test ! -e ${p.omnigent-host}/bin/omnigent-server
          touch $out
        '';
  };

  desktopChecks = lib.optionalAttrs isLinux {
    pkg-omnigent-desktop = p.omnigent-desktop;

    desktop-nix-integration =
      pkgs.runCommand "omnigent-desktop-integration"
        {
          nativeBuildInputs = [ pkgs.nodejs_22 ];
        }
        ''
          app=${p.omnigent-desktop}/lib/omnigent-desktop/web/electron
          # Auto-updater is hard-disabled.
          grep -q 'updatesEnabled: false' $app/src/main.js
          # The wrapper hands the app the co-built CLI and runs nixpkgs' Electron.
          grep -q 'OMNIGENT_NIX_CLI' ${p.omnigent-desktop}/bin/omnigent-desktop
          grep -q '${p.omnigent}/bin/omnigent' ${p.omnigent-desktop}/bin/omnigent-desktop
          grep -q '${pkgs.electron}' ${p.omnigent-desktop}/bin/omnigent-desktop

          # CLI discovery prefers the Nix CLI even with an empty PATH.
          cat > probe.js <<EOF
          const m = require("$app/src/omnigent_cli.js");
          const r = m.resolveCliPath(null, {
            isExecutableFile: (p) => p === process.env.OMNIGENT_NIX_CLI,
            whichOmnigent: () => "/somewhere/else/omnigent",
            candidatePaths: () => [],
          });
          if (!r || r.source !== "nix" || r.path !== process.env.OMNIGENT_NIX_CLI) {
            console.error("unexpected", r); process.exit(1);
          }
          EOF
          OMNIGENT_NIX_CLI=${p.omnigent}/bin/omnigent PATH= ${pkgs.nodejs_22}/bin/node probe.js

          # No installer fetched Electron or application code into the output.
          ! find ${p.omnigent-desktop} -name 'electron-v*' | grep -q .
          touch $out
        '';
  };
in
moduleChecks // hmChecks // runtimeChecks // desktopChecks
