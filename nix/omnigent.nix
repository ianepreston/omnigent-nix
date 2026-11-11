# The shared runtime: the three lockstep Python distributions (omnigent,
# omnigent-client, omnigent-ui-sdk) installed as one application closure, with
# the prebuilt web UI, and with self-update disabled.
{
  lib,
  python3,
  callPackage,
  upstream,
  webAssets,
  # Optional extras. `withKubernetes` is the server variant for the managed
  # Kubernetes sandbox provider (spec: "Managed-sandbox support").
  withKubernetes ? false,
}:
let
  # Build the ABI-sensitive dependencies at the versions upstream locks (see
  # `pythonPins` in source.nix) so every runtime-deps check passes unrelaxed.
  pin =
    prev: name:
    prev.${name}.overridePythonAttrs (
      o:
      let
        v = upstream.pythonPins.${name};
      in
      {
        inherit (v) version;
        src = prev.fetchPypi {
          pname = v.sdistName;
          inherit (v) version sha256;
        };
        patches = [ ];
        doCheck = false;
      }
      // lib.optionalAttrs (name == "openai") {
        # nixpkgs' openai is a newer major (3.x) whose recipe no longer fits
        # the locked 2.x sdist, so declare 2.x's own: its postPatch relaxes a
        # different exact hatchling pin (and patches tests we don't run), its
        # build-system dropped hatch-fancy-pypi-readme, and its dependencies
        # swapped httpx for httpx2 and dropped distro/tqdm. The list below is
        # 2.41.0's pyproject `dependencies`. `--replace-fail` breaks loudly if
        # a pin bump changes the hatchling pin.
        postPatch = ''
          substituteInPlace pyproject.toml \
            --replace-fail '"hatchling==1.26.3"' '"hatchling"'
        '';
        build-system = [
          prev.hatchling
          prev.hatch-fancy-pypi-readme
        ];
        dependencies = with prev; [
          anyio
          distro
          httpx
          jiter
          pydantic
          sniffio
          tqdm
          typing-extensions
        ];
      }
      // lib.optionalAttrs (name == "openai-agents") {
        # Newer nixpkgs openai-agents dropped types-requests, which the locked
        # 0.13.x still lists as a runtime dependency.
        dependencies = (o.dependencies or [ ]) ++ [ prev.types-requests ];
      }
      // lib.optionalAttrs (name == "mcp") {
        # 2.x split types into a separate package that 1.x does not have, and
        # 1.x needs two packages the 2.x set dropped.
        dependencies = lib.filter (d: (d.pname or "") != "mcp-types") (o.dependencies or [ ]) ++ [
          prev.httpx-sse
          prev.pydantic-settings
        ];
      }
    );
  python = python3.override {
    self = python;
    packageOverrides =
      _: prev:
      lib.genAttrs (lib.attrNames upstream.pythonPins) (pin prev)
      // {
        # Both suites have one builder-sensitive test that failed in PR CI.
        # Keep the rest of their checks enabled; remove these when nixpkgs does.
        pyarrow = prev.pyarrow.overridePythonAttrs (o: {
          disabledTestPaths = (o.disabledTestPaths or [ ]) ++ [
            # Memory use differs slightly between runs (4112 vs 3856 bytes).
            "pyarrow/tests/test_csv.py::TestThreadedStreamingCSVRead::test_batch_lifetime"
          ];
        });
        uvloop = prev.uvloop.overridePythonAttrs (o: {
          disabledTestPaths = (o.disabledTestPaths or [ ]) ++ [
            # https://github.com/NixOS/nixpkgs/issues/572977
            "tests/test_process.py::Test_UV_Process_Delayed::test_process_delayed_stdio__not_paused__no_stdin"
          ];
        });
      };
  };
  py = python.pkgs;

  # Not in nixpkgs. Pure Python; requires google-re2 (in nixpkgs), lark,
  # jmespath, pendulum, pyyaml. Installed from the pinned upstream wheel.
  cel-python = py.buildPythonPackage {
    pname = "cel-python";
    inherit (upstream.celPython) version;
    format = "wheel";
    src = py.fetchPypi {
      pname = "cel_python";
      inherit (upstream.celPython) version;
      format = "wheel";
      dist = "py3";
      python = "py3";
      sha256 = upstream.celPython.wheelSha256;
    };
    dependencies = with py; [
      google-re2
      jmespath
      lark
      pendulum
      pyyaml
    ];
    pythonImportsCheck = [ "celpy" ];
  };

  # Both SDK pyprojects cap `hatchling<1.32.0` because 1.32 writes core
  # metadata 2.5, which twine/PyPI do not accept yet. That only matters for
  # uploading; a Nix build never uploads, and nixpkgs ships hatchling 1.32, so
  # drop the cap. `--replace-fail` breaks the build once upstream removes it,
  # which is the cue to delete this.
  dropHatchlingCap = ''
    substituteInPlace pyproject.toml \
      --replace-fail '"hatchling>=1.27,<1.32.0"' '"hatchling>=1.27"'
  '';

  # `omnigent-client` and `omnigent-ui-sdk` are built from the same source
  # revision and installed alongside the main package. omnigent-client's
  # requirement on `omnigent==X` is a metadata-only back-edge of a cycle:
  # omnigent-client genuinely imports `omnigent.server.schemas` etc. at runtime,
  # so it is only valid inside this one closure (see `passthru.tests`).
  omnigent-client = py.buildPythonPackage {
    pname = "omnigent-client";
    inherit (upstream) version src;
    pyproject = true;
    sourceRoot = "${upstream.src.name}/sdks/python-client";
    postPatch = dropHatchlingCap;
    build-system = [ py.hatchling ];
    dependencies = with py; [
      httpx
      pydantic
    ];
    # Break the metadata cycle; omnigent comes from the same closure.
    pythonRemoveDeps = [ "omnigent" ];
    doCheck = false;
  };

  omnigent-ui-sdk = py.buildPythonPackage {
    pname = "omnigent-ui-sdk";
    inherit (upstream) version src;
    pyproject = true;
    sourceRoot = "${upstream.src.name}/sdks/ui";
    postPatch = dropHatchlingCap;
    build-system = [ py.hatchling ];
    dependencies =
      (with py; [
        rich
        prompt-toolkit
        pyyaml
      ])
      ++ [ omnigent-client ];
    doCheck = false;
  };
  omnigent-lib = py.buildPythonPackage {
    pname = "omnigent";
    inherit (upstream) version src;
    pyproject = true;

    patches = [ ./patches/nix-build-and-upgrade.patch ];

    build-system = [ py.setuptools ];

    # Phase split: the web UI is built offline by `webAssets`; the Python phase
    # must not try to run pnpm.
    env = {
      OMNIGENT_SKIP_WEB_UI = "true";
      OMNIGENT_BUILD_COMMIT_SHA = upstream.commit;
    };

    postPatch = ''
      mkdir -p omnigent/server/static
      cp -r ${webAssets}/web-ui omnigent/server/static/web-ui
      chmod -R u+w omnigent/server/static/web-ui
    '';

    dependencies =
      (with py; [
        pyyaml
        json5
        openai
        rich
        prompt-toolkit
        mcp
        starlette
        uvicorn
        websockets
        httpx
        ftfy
        psutil
        keyring
        pillow
        tomlkit
        alembic
        anyio
        cachetools
        filelock
        click
        fastapi
        pexpect
        pyte
        pydantic
        sqlalchemy
        zstandard
        tiktoken
        opentelemetry-api
        claude-agent-sdk
        openai-agents
        pyjwt
        argon2-cffi
        packaging
        certifi
        protobuf
        python-dateutil
        # PostgreSQL backend (the `postgres` extra): the production database.
        psycopg
      ])
      ++ py.uvicorn.optional-dependencies.standard
      ++ py.pyjwt.optional-dependencies.crypto
      ++ lib.optionals withKubernetes [ py.kubernetes ]
      ++ [
        cel-python
        omnigent-client
        omnigent-ui-sdk
      ];

    # The package's own pytest suite needs network, harness CLIs and a database;
    # behaviour is covered by `checks.*`.
    doCheck = false;

    pythonImportsCheck = [
      "agents"
      "mcp"
      "websockets"
      "omnigent"
      "omnigent.cli"
      "omnigent.server.app"
      "omnigent.host.mcp_tools"
      "omnigent.host.connect"
      "omnigent_client"
      "omnigent_ui_sdk"
    ];

    postInstall = ''
      # Docker-image entrypoint: the supported "external runners only" server
      # (no in-process harness execution; DATABASE_URL + config file driven).
      install -Dm644 deploy/docker/entrypoint.py $out/libexec/omnigent/server_entrypoint.py
    '';

    meta = {
      description = "Omnigent Python distributions (omnigent, omnigent-client, omnigent-ui-sdk)";
      license = lib.licenses.asl20;
    };
  };

  # `sys.executable` must be an interpreter that can import the closure:
  # omnigent re-spawns itself (`sys.executable -P -m omnigent.runner._entry`,
  # the daemons, `sys.executable -I` git helpers). A site-patched script wrapper
  # only fixes the first process, so run everything on one `withPackages`
  # interpreter instead.
  pythonEnv = python.withPackages (_: [ omnigent-lib ]);
in
callPackage ./launchers.nix { } {
  pname = "omnigent";
  inherit (upstream) version;
  inherit pythonEnv;
  serverEntrypoint = "${omnigent-lib}/libexec/omnigent/server_entrypoint.py";
  passthru = {
    inherit
      webAssets
      cel-python
      omnigent-client
      omnigent-ui-sdk
      omnigent-lib
      pythonEnv
      ;
    # Fixed-output sources of the pinned dependencies, for hash-independence checks.
    pythonSources = lib.mapAttrs (n: _: py.${n}.src) upstream.pythonPins;
    # The pinned cel-python wheel (celPython in source.nix), likewise.
    celPythonSource = cel-python.src;
  };
  meta = {
    description = "Declarative agent authoring and runtime framework (server, CLI, host)";
    homepage = "https://github.com/omnigent-ai/omnigent";
    license = lib.licenses.asl20;
    mainProgram = "omnigent";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
