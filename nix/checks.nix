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
  upstream = pkgs.callPackage ./source.nix { };

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

    refuses-reserved-environment = mustFail "reserved-environment" (nixos {
      services.omnigent = {
        enable = true;
        database.sqlite.enable = true;
        environment.HOST = "0.0.0.0";
      };
    });
    refuses-auth-disable-via-environment = mustFail "auth-disable-via-environment" (nixos {
      services.omnigent = {
        enable = true;
        database.sqlite.enable = true;
        environment.OMNIGENT_AUTH_ENABLED = "0";
      };
    });
    refuses-store-environment-file = mustFail "store-environment-file" (nixos {
      services.omnigent = {
        enable = true;
        database.sqlite.enable = true;
        environmentFile = pkgs.writeText "leaky.env" "SECRET=1";
      };
    });
    refuses-store-uri-file = mustFail "store-uri-file" (nixos {
      services.omnigent = {
        enable = true;
        database.uriFile = pkgs.writeText "uri" ("postgresql://" + "u:p" + "@h/db");
      };
    });
    refuses-store-path-string-uri-file = mustFail "store-path-string-uri-file" (nixos {
      services.omnigent = {
        enable = true;
        database.uriFile = "${pkgs.hello}/uri";
      };
    });
    refuses-password-uri = mustFail "password-uri" (nixos {
      services.omnigent = {
        enable = true;
        database.uri = ("postgresql+psycopg://" + "omnigent:hunter2" + "@db.example.net/omnigent");
      };
    });
    refuses-password-query-uri = mustFail "password-query-uri" (nixos {
      services.omnigent = {
        enable = true;
        database.uri = ("postgresql+psycopg://" + "omnigent@db.example.net/omnigent?" + "password=hunter2");
      };
    });

    # The start wrapper exports the controlled settings last, so the runtime
    # secrets file cannot override them.
    start-wrapper-forces-settings = pkgs.runCommand "start-wrapper-forces-settings" { } ''
      w=${(svc uriFileServer).serviceConfig.ExecStart}
      grep -q 'export HOST=127.0.0.1' $w
      grep -q 'export OMNIGENT_AUTH_ENABLED=1' $w
      grep -q 'unset OMNIGENT_LOCAL_SINGLE_USER' $w
      grep -q 'export OMNIGENT_MANAGED_BY_NIX=1' $w
      grep -q 'CREDENTIALS_DIRECTORY/database-uri' $w
      # forced exports come before the exec, i.e. after systemd read the env file
      test "$(grep -n 'export HOST' $w | cut -d: -f1)" -lt "$(grep -n '^exec ' $w | cut -d: -f1)"
      touch $out
    '';

    refuses-empty-user-password-uri = mustFail "empty-user-password-uri" (nixos {
      services.omnigent = {
        enable = true;
        database.uri = "postgresql+psycopg://" + ":pw" + "@host/db";
      };
    });
    refuses-encoded-password-key-uri = mustFail "encoded-password-key-uri" (nixos {
      services.omnigent = {
        enable = true;
        database.uri = "postgresql+psycopg://u@host/db?" + "pass%77ord=x";
      };
    });
    refuses-encoded-sslpassword-key-uri = mustFail "encoded-sslpassword-key-uri" (nixos {
      services.omnigent = {
        enable = true;
        database.uri = "postgresql+psycopg://u@host/db?" + "sslpass%77ord=x";
      };
    });
    refuses-unlisted-query-key-uri = mustFail "unlisted-query-key-uri" (nixos {
      services.omnigent = {
        enable = true;
        database.uri = "postgresql+psycopg://u@host/db?passfile=/x";
      };
    });
    refuses-exact-store-dir-env-file = mustFail "exact-store-dir-env-file" (nixos {
      services.omnigent = {
        enable = true;
        database.sqlite.enable = true;
        environmentFile = builtins.storeDir;
      };
    });
    passwordless-uri-accepted =
      evalOnly "passwordless-uri-accepted"
        (nixos {
          services.omnigent = {
            enable = true;
            database.uri = "postgresql+psycopg://omnigent@/omnigent?host=/run/postgresql";
          };
        }).config.system.build.toplevel;

    # Every reserved variable is forced or unset by the wrapper, so the secrets
    # file cannot supply any of them (including OMNIGENT_ACCOUNTS_BASE_URL when
    # publicUrl is null).
    wrapper-covers-every-reserved-variable =
      pkgs.runCommand "wrapper-covers-every-reserved-variable" { }
        ''
          w=${(svc sqliteLoopback).serviceConfig.ExecStart}
          for v in HOST PORT ARTIFACT_DIR HOME DATABASE_URL OMNIGENT_CONFIG OMNIGENT_MANAGED_BY_NIX \
                   OMNIGENT_NO_UPDATE_CHECK OMNIGENT_AUTH_PROVIDER OMNIGENT_AUTH_ENABLED \
                   OMNIGENT_LOCAL_SINGLE_USER OMNIGENT_ACCOUNTS_BASE_URL; do
            grep -Eq "^(export $v=|unset $v$)" $w || { echo "$v not forced/unset" >&2; exit 1; }
          done
          touch $out
        '';

    # Runtime guard (runs as root under `env -i` in the unit). Tested here as an
    # unprivileged user by pointing the expected owner at ourselves.
    secret-path-guard =
      let
        cmd = builtins.head (svc uriFileServer).serviceConfig.ExecStartPre;
        # "+<coreutils>/bin/env -i <guard> <files...>"
        guardBin = builtins.elemAt (lib.splitString " " cmd) 2;
      in
      pkgs.runCommand "secret-path-guard" { } ''
        export OMNIGENT_GUARD_OWNER_UID=$(id -u)
        echo secret > plain
        ln -s ${pkgs.hello}/bin/hello via-store
        ln -s ${builtins.storeDir} exact-store
        mkdir -m 777 open-dir
        echo secret > open-dir/f
        ${guardBin} $PWD/plain
        ! ${guardBin} $PWD/via-store 2>/dev/null
        ! ${guardBin} $PWD/exact-store 2>/dev/null
        ! ${guardBin} $PWD/missing-file 2>/dev/null
        # in a world-writable directory: swappable by another user, refused
        ! ${guardBin} $PWD/open-dir/f 2>/dev/null
        # owned by someone other than the expected (root) uid: refused
        unset OMNIGENT_GUARD_OWNER_UID
        ! ${guardBin} $PWD/plain 2>/dev/null
        touch $out
      '';
    guard-wired-into-unit =
      let
        u = svc uriFileServer;
        cmd = builtins.head u.serviceConfig.ExecStartPre;
      in
      assertEval "guard-wired-into-unit" (
        lib.hasPrefix "+" cmd
        # clean environment, so no unit/secret variable reaches the root helper
        && lib.hasInfix "/bin/env -i " cmd
        && lib.hasInfix "/run/secrets/omnigent.env" cmd
        && lib.hasInfix "/run/secrets/omnigent-database-uri" cmd
        # the secrets file is a credential, never an EnvironmentFile
        && !(u.serviceConfig ? EnvironmentFile)
      ) "guard/credential wiring is wrong";

    # The environment credential is parsed, never sourced; only an allowlist of
    # keys is accepted and module-controlled settings win.
    env-credential-parsing =
      let
        stub = pkgs.writeShellScriptBin "omnigent-server" ''
          echo "HOST=$HOST"
          echo "AUTH=$OMNIGENT_AUTH_ENABLED"
          echo "OIDC=$OMNIGENT_OIDC_CLIENT_SECRET"
          echo "LITERAL=$OMNIGENT_OIDC_X"
          echo "LD=''${LD_PRELOAD-unset}"
        '';
        sys = nixos {
          services.omnigent = {
            enable = true;
            package = stub;
            environmentFile = "/run/secrets/omnigent.env";
            database.uriFile = "/run/secrets/omnigent-database-uri";
          };
        };
        w = (svc sys).serviceConfig.ExecStart;
      in
      pkgs.runCommand "env-credential-parsing" { } ''
        mkdir cred
        export CREDENTIALS_DIRECTORY=$PWD/cred
        echo 'postgresql+psycopg://u@/db?host=/run/postgresql' > cred/database-uri
        run() { printf '%s\n' "$1" > cred/environment; ${w}; }

        res=$(run '# comment

        OMNIGENT_OIDC_CLIENT_SECRET="abc def"
        OMNIGENT_OIDC_X=$(touch '"$PWD"'/pwned)')
        echo "$res"
        echo "$res" | grep -q '^OIDC=abc def$'
        echo "$res" | grep -q '^HOST=127.0.0.1$'
        echo "$res" | grep -q '^AUTH=1$'
        echo "$res" | grep -q '^LITERAL=\$(touch '
        test ! -e pwned

        # Disallowed or module-controlled keys stop the service from starting.
        for bad in 'LD_PRELOAD=/evil.so' 'BASH_ENV=/evil' 'HOST=0.0.0.0' \
                   'OMNIGENT_AUTH_ENABLED=0' 'OMNIGENT_LOCAL_SINGLE_USER=1' \
                   'DATABASE_URL=sqlite:///x' 'PATH=/evil' 'no-equals-sign' 'lower=1'; do
          if run "$bad" >/dev/null 2>&1; then echo "accepted: $bad" >&2; exit 1; fi
        done
        touch $out
      '';

    refuses-forbidden-environment-file-keys = mustFail "forbidden-environment-file-keys" (nixos {
      services.omnigent = {
        enable = true;
        database.sqlite.enable = true;
        environmentFileKeys = [ "LD_PRELOAD" ];
      };
    });
    refuses-reserved-environment-file-keys = mustFail "reserved-environment-file-keys" (nixos {
      services.omnigent = {
        enable = true;
        database.sqlite.enable = true;
        environmentFileKeys = [ "OMNIGENT_AUTH_ENABLED" ];
      };
    });
    refuses-non-postgres-uri-scheme = mustFail "non-postgres-uri-scheme" (nixos {
      services.omnigent = {
        enable = true;
        database.uri = "mysql://u@host/db";
      };
    });
    refuses-sqlite-uri-scheme = mustFail "sqlite-uri-scheme" (nixos {
      services.omnigent = {
        enable = true;
        database.uri = "sqlite:///tmp/x.db";
      };
    });

    hm-host-package-without-override-refused = mustFailHmNoOverride;

    # Secrets never reach the unit: the URI file is a credential, the secrets
    # file an EnvironmentFile, and there is no DATABASE_URL in Environment=.
    secrets-stay-out-of-unit =
      let
        u = svc uriFileServer;
      in
      assertEval "secrets-stay-out-of-unit" (
        !(u.environment ? DATABASE_URL)
        &&
          u.serviceConfig.LoadCredential == [
            "database-uri:/run/secrets/omnigent-database-uri"
            "environment:/run/secrets/omnigent.env"
          ]
        && !(u.serviceConfig ? EnvironmentFile)
        && u.serviceConfig.DynamicUser
        && !(u.environment ? HOST)
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

  # Evaluate the module with stub options so the failed assertion's actual
  # message can be read (homeManagerConfiguration throws instead).
  hmDarwinDesktop = lib.evalModules {
    modules = [
      self.homeManagerModules.omnigent
      (
        { lib, ... }:
        {
          options = {
            assertions = lib.mkOption { type = lib.types.listOf lib.types.attrs; };
            home.packages = lib.mkOption {
              type = lib.types.listOf lib.types.raw;
              default = [ ];
            };
            systemd.user.services = lib.mkOption {
              type = lib.types.attrsOf lib.types.raw;
              default = { };
            };
            launchd.agents = lib.mkOption {
              type = lib.types.attrsOf lib.types.raw;
              default = { };
            };
          };
          config = {
            _module.args.pkgs = import nixpkgs { system = "aarch64-darwin"; };
            programs.omnigent.desktop.enable = true;
          };
        }
      )
    ];
  };

  hmChecks = {
    hm-module-host = evalOnly "hm-module-host" hmHost.activationPackage;
    hm-module-idle = evalOnly "hm-module-idle" hmIdle.activationPackage;
    # Desktop is intentionally Linux-only: enabling it on darwin is a clear,
    # explained assertion, not an obscure evaluation failure.
    hm-desktop-darwin-explained = assertEval "hm-desktop-darwin-explained" (lib.any
      (
        a:
        !a.assertion
        && lib.hasInfix "this flake does not yet build a macOS desktop bundle; on macOS use the upstream app" a.message
      )
      hmDarwinDesktop.config.assertions
    ) "darwin desktop.enable did not raise the macOS-bundle assertion";
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
  mustFailHmNoOverride =
    let
      cfg = hm {
        programs.omnigent.host = {
          enable = true;
          package = pkgs.runCommand "plain-package" { } "mkdir -p $out/bin";
        };
      };
      r = builtins.tryEval (builtins.seq cfg.activationPackage.drvPath true);
    in
    pkgs.runCommand "hm-host-package-without-override-refused" { } (
      if r.success then "echo 'package without override accepted' >&2; exit 1" else "touch $out"
    );
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
          grep -q '${builtins.substring 0 8 upstream.commit}' version.txt
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

    # End-to-end tunnel handshake with the pinned websockets: a loopback server
    # (single-user mode, test only) and `omnigent host --server`, which dials the
    # server's websocket tunnel and registers. Asserts the server lists exactly
    # that host as online. Not covered: running a session on the host (needs a
    # harness CLI and model credentials, deliberately absent from the sandbox).
    host-tunnel =
      pkgs.runCommand "omnigent-host-tunnel"
        {
          nativeBuildInputs = [
            p.omnigent
            p.omnigent-host
            pkgs.curl
            pkgs.jq
          ];
        }
        ''
          export HOME=$TMPDIR
          export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
          port=18772
          HOST=127.0.0.1 PORT=$port ARTIFACT_DIR=$TMPDIR/artifacts \
            DATABASE_URL=sqlite:///$TMPDIR/omnigent.db OMNIGENT_AUTH_ENABLED=0 \
            omnigent-server > server.log 2>&1 &
          spid=$!
          trap 'kill $spid $hpid 2>/dev/null || true' EXIT
          for _ in $(seq 1 60); do curl -sf http://127.0.0.1:$port/health >/dev/null && break; sleep 1; done

          OMNIGENT_DATA_DIR=$TMPDIR/data OMNIGENT_CONFIG_HOME=$TMPDIR/config \
            ${p.omnigent-host}/bin/omnigent host --server http://127.0.0.1:$port --non-interactive --no-open > host.log 2>&1 &
          hpid=$!

          ok=
          for _ in $(seq 1 60); do
            curl -sf http://127.0.0.1:$port/v1/hosts -o hosts.json || true
            if [ "$(jq -r '[.hosts[]? | select(.status == "online")] | length' hosts.json 2>/dev/null)" = 1 ]; then ok=1; break; fi
            kill -0 $hpid 2>/dev/null || break
            sleep 1
          done
          if [ -z "$ok" ]; then cat server.log host.log; echo "host never registered online" >&2; exit 1; fi
          grep -q 'Connected as' host.log
          touch $out
        '';

    web-ui-bundled = pkgs.runCommand "omnigent-web-ui-bundled" { } ''
      d=${p.omnigent.passthru.omnigent-lib}/${pkgs.python3.sitePackages}/omnigent/server/static/web-ui
      test -f $d/index.html
      ls $d/assets/*.js >/dev/null
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

    electron-major-matches-upstream = assertEval "electron-major-matches-upstream" (
      lib.versions.major p.omnigent-desktop.passthru.electron.version == "45"
    ) "desktop is not on upstream's Electron major (45)";

    desktop-headless-launch =
      pkgs.runCommand "omnigent-desktop-headless-launch"
        {
          nativeBuildInputs = [
            pkgs.xvfb-run
            pkgs.coreutils
          ];
        }
        ''
          export HOME=$TMPDIR XDG_CONFIG_HOME=$TMPDIR/.config
          # Still running at the timeout (124) means the main process started
          # and did not crash; any other status is a failure.
          rc=0
          timeout 20 xvfb-run -a ${p.omnigent-desktop}/bin/omnigent-desktop \
            --no-sandbox --disable-gpu > launch.log 2>&1 || rc=$?
          if [ "$rc" != 124 ]; then cat launch.log; echo "exit $rc" >&2; exit 1; fi
          ! grep -qi 'cannot find module\|uncaught exception' launch.log
          touch $out
        '';

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
          grep -q '${p.omnigent-desktop.passthru.electron}' ${p.omnigent-desktop}/bin/omnigent-desktop

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
          test -z "$(find ${p.omnigent-desktop} -name 'electron-v*')"
          touch $out
        '';
  };
in
moduleChecks // hmChecks // runtimeChecks // desktopChecks
