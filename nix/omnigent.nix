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
  py = python3.pkgs;

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
    pname = "omnigent-lib";
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

    # The wheel pins `websockets<15` (a macOS-client regression upstream); the
    # Linux asyncio client and uvicorn's server side are unaffected by it.
    # Pins that nixpkgs overshoots are relaxed rather than shipping a second copy.
    pythonRelaxDeps = [
      "websockets"
      "starlette"
      "keyring"
      "protobuf"
      "pillow"
      "certifi"
      "openai"
      "claude-agent-sdk"
      "openai-agents"
      "mcp"
      "click"
    ];

    # The package's own pytest suite needs network, harness CLIs and a database;
    # behaviour is covered by `checks.*` (CLI, import, `-I`, server smoke).
    doCheck = false;

    pythonImportsCheck = [
      "omnigent"
      "omnigent.cli"
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
  pythonEnv = python3.withPackages (_: [ omnigent-lib ]);
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
  };
  meta = {
    description = "Declarative agent authoring and runtime framework (server, CLI, host)";
    homepage = "https://github.com/omnigent-ai/omnigent";
    license = lib.licenses.asl20;
    mainProgram = "omnigent";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
