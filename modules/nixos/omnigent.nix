# Core server module. Owns the systemd service, its state directory and a
# private listener. It deliberately knows nothing about Caddy, PostgreSQL
# deployment, secret managers or backups: consumers compose those around the
# published options (`listen`, `publicUrl`, `healthPath`, `database.*`).
{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.omnigent;
  yaml = pkgs.formats.yaml { };

  loopbackAddresses = [
    "127.0.0.1"
    "::1"
    "localhost"
  ];
  isLoopback = lib.elem cfg.listen.address loopbackAddresses;

  stateName = lib.removePrefix "/var/lib/" cfg.stateDir;
  settingsFile = yaml.generate "omnigent-server.yaml" cfg.settings;

  hasUri = cfg.database.uri != null;
  hasUriFile = cfg.database.uriFile != null;
  # A literal URI is accepted only in an explicitly passwordless form:
  #   scheme://[user@][host[:port]][/dbname][?key=value&...]
  # - userinfo is a bare username (no ':' and no '%', so no password component)
  # - the host contains no '@', '%' or '/'
  # - query keys come from a short allowlist and values are plain characters
  #   (no '%'), so URL-encoded key names cannot smuggle a password parameter.
  # Anything else must go through `database.uriFile`.
  safeQueryKeys = [
    "host"
    "port"
    "sslmode"
    "sslrootcert"
    "application_name"
    "connect_timeout"
  ];
  uriParts =
    if hasUri then
      builtins.match "([a-z][a-z0-9+.-]*)://(([A-Za-z0-9_.-]+)@)?([]A-Za-z0-9_.:[-]*)(/[A-Za-z0-9_./-]*)?(\\?([^#]*))?" cfg.database.uri
    else
      null;
  safeQuery =
    q0:
    q0 == null
    || q0 == ""
    || lib.all (
      kv:
      let
        m = builtins.match "([a-z_]+)=([A-Za-z0-9_./:-]*)" kv;
      in
      m != null && lib.elem (builtins.head m) safeQueryKeys
    ) (lib.splitString "&" q0);
  uriIsSafe = hasUri && uriParts != null && safeQuery (builtins.elemAt uriParts 6);
  databaseSources = lib.count (x: x) [
    hasUri
    hasUriFile
    cfg.database.sqlite.enable
  ];

  # Names the module controls. They are rejected in `environment` and re-forced
  # by the start wrapper after systemd has read `environmentFile`, so neither a
  # caller nor a runtime secrets file can weaken the validated configuration.
  reservedEnv = [
    "HOST"
    "PORT"
    "ARTIFACT_DIR"
    "HOME"
    "DATABASE_URL"
    "OMNIGENT_CONFIG"
    "OMNIGENT_MANAGED_BY_NIX"
    "OMNIGENT_NO_UPDATE_CHECK"
    "OMNIGENT_AUTH_PROVIDER"
    "OMNIGENT_AUTH_ENABLED"
    "OMNIGENT_LOCAL_SINGLE_USER"
    "OMNIGENT_ACCOUNTS_BASE_URL"
  ];
  badEnv = lib.filter (n: lib.elem n reservedEnv) (lib.attrNames cfg.environment);

  inStore =
    path: toString path == builtins.storeDir || lib.hasPrefix "${builtins.storeDir}/" (toString path);

  # Runtime counterpart of the lexical store-path assertions: a path such as
  # /run/secrets/x may be a symlink into the store. Runs privileged (`+`)
  # before the service starts and refuses if any secret file resolves there.
  guard = pkgs.writeShellScript "omnigent-secret-path-guard" ''
    set -eu
    for f in "$@"; do
      r=$(${pkgs.coreutils}/bin/realpath -e -- "$f") || {
        echo "omnigent: cannot resolve secret file $f" >&2
        exit 1
      }
      case "$r" in
        ${builtins.storeDir}|${builtins.storeDir}/*)
          echo "omnigent: secret file $f resolves into the Nix store ($r); refusing to start" >&2
          exit 1
          ;;
      esac
    done
  '';
  guardedFiles =
    lib.optional (cfg.environmentFile != null) (toString cfg.environmentFile)
    ++ lib.optional hasUriFile (toString cfg.database.uriFile);

  bracketed =
    if lib.hasInfix ":" cfg.listen.address then "[${cfg.listen.address}]" else cfg.listen.address;

  q = lib.escapeShellArg;

  # Reads secrets from systemd credentials at start so nothing secret is ever
  # a Nix value, a unit `Environment=` line, or a store path. Security-relevant
  # settings are exported here, last, so `environmentFile` cannot override them.
  start = pkgs.writeShellScript "omnigent-server-start" ''
    set -eu
    export HOST=${q cfg.listen.address}
    export PORT=${q (toString cfg.listen.port)}
    export ARTIFACT_DIR=${q "${cfg.stateDir}/artifacts"}
    export HOME=${q cfg.stateDir}
    export OMNIGENT_CONFIG=${q "${settingsFile}"}
    export OMNIGENT_MANAGED_BY_NIX=1
    export OMNIGENT_NO_UPDATE_CHECK=1
    # Authentication can never be switched off from the environment file.
    export OMNIGENT_AUTH_ENABLED=1
    unset OMNIGENT_LOCAL_SINGLE_USER
    ${
      if cfg.auth.provider != null then
        "export OMNIGENT_AUTH_PROVIDER=${q cfg.auth.provider}"
      else
        "unset OMNIGENT_AUTH_PROVIDER"
    }
    ${
      if cfg.publicUrl != null then
        "export OMNIGENT_ACCOUNTS_BASE_URL=${q cfg.publicUrl}"
      else
        "unset OMNIGENT_ACCOUNTS_BASE_URL"
    }
    ${lib.optionalString hasUri "export DATABASE_URL=${q cfg.database.uri}"}
    ${lib.optionalString cfg.database.sqlite.enable "export DATABASE_URL=${q "sqlite:///${cfg.stateDir}/omnigent.db"}"}
    ${lib.optionalString hasUriFile ''
      DATABASE_URL="$(< "$CREDENTIALS_DIRECTORY/database-uri")"
      export DATABASE_URL
    ''}
    exec ${cfg.package}/bin/omnigent-server
  '';
in
{
  options.services.omnigent = {
    enable = lib.mkEnableOption "the Omnigent server (control plane: API, web UI, persistence)";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.omnigent;
      defaultText = lib.literalExpression "omnigent.packages.\${system}.omnigent";
      description = ''
        The Omnigent runtime. Server, hosts and desktop clients are released as
        one lockstep unit: keep every package on the same flake revision.
      '';
    };

    listen = {
      address = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1";
        description = ''
          Address to bind. Loopback by default; the firewall is the consumer's
          business. A non-loopback address requires {option}`services.omnigent.auth.provider`.
        '';
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = 8000;
        description = "TCP port to listen on.";
      };
    };

    publicUrl = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "https://omnigent.example.net";
      description = ''
        Externally visible origin, used for redirects, cookies and the URL given
        to provider-created hosts. May be null for a loopback-only development
        server.
      '';
    };

    healthPath = lib.mkOption {
      type = lib.types.str;
      default = "/health";
      readOnly = true;
      description = "Unauthenticated health endpoint, for a reverse proxy or monitor.";
    };

    listenUrl = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = "http://${bracketed}:${toString cfg.listen.port}";
      description = "Origin of the private listener (contract for reverse-proxy adapters).";
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/omnigent";
      description = ''
        State directory (artifacts, generated cookie secret, SQLite database if
        enabled). Must be `/var/lib/<name>`; systemd creates and owns it.
      '';
    };

    user = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Run as this existing user instead of a `DynamicUser`. Escape hatch for
        setups that need a stable identity (for example peer-authenticated
        PostgreSQL over a unix socket).
      '';
    };

    group = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Group for a fixed {option}`user`.";
    };

    settings = lib.mkOption {
      type = yaml.type;
      default = { };
      example = lib.literalExpression ''{ restrict_to_agent_names = [ "polly" ]; }'';
      description = ''
        Non-secret Omnigent server YAML (policies, agent selection, branding…),
        rendered to a store file. Never put credentials here.
      '';
    };

    environment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = ''
        Extra non-secret environment variables for the service. Names the module
        controls (host, port, database, authentication, config path, update
        switches) are rejected here and cannot be overridden by
        {option}`environmentFile` either.
      '';
    };

    environmentFile = lib.mkOption {
      type = lib.types.nullOr lib.types.externalPath;
      default = null;
      example = "/run/secrets/omnigent.env";
      description = ''
        File read by systemd at start (`EnvironmentFile=`) holding secrets: OIDC
        client secret, cookie secret, provider credentials. Its contents never
        enter the Nix store.
      '';
    };

    auth.provider = lib.mkOption {
      type = lib.types.nullOr (
        lib.types.enum [
          "accounts"
          "oidc"
          "header"
        ]
      );
      default = null;
      description = ''
        Explicit authentication mode (`OMNIGENT_AUTH_PROVIDER`): built-in
        `accounts`, an `oidc` identity provider (configure via
        {option}`environmentFile`), or `header` (identity injected by a trusted
        reverse proxy). Required for a non-loopback listener. When null, the
        upstream container default applies (`accounts`).
      '';
    };

    database = {
      uriFile = lib.mkOption {
        type = lib.types.nullOr lib.types.externalPath;
        default = null;
        example = "/run/secrets/omnigent-database-uri";
        description = ''
          File containing the SQLAlchemy/PostgreSQL URI, loaded as a systemd
          credential. Preferred: keeps the password out of the store.
        '';
      };
      uri = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Literal database URI. It lands in the store and the unit, so a URI
          that carries a password is rejected: use {option}`uriFile`. Only for a
          URI without a secret (for example a peer-authenticated socket).
        '';
      };
      sqlite.enable = lib.mkEnableOption ''
        SQLite in the state directory. Single-instance development only; not
        for a durable or multi-user server'';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = databaseSources == 1;
        message = "services.omnigent: set exactly one of database.uriFile, database.uri or database.sqlite.enable.";
      }
      {
        assertion = isLoopback || cfg.auth.provider != null;
        message = ''
          services.omnigent.listen.address is ${cfg.listen.address} (not loopback):
          set services.omnigent.auth.provider explicitly so the server is never
          exposed without a chosen authentication mode.
        '';
      }
      {
        assertion = lib.hasPrefix "/var/lib/" cfg.stateDir && !(lib.hasInfix ".." cfg.stateDir);
        message = "services.omnigent.stateDir must be /var/lib/<name>.";
      }
      {
        assertion = cfg.user != null || cfg.group == null;
        message = "services.omnigent.group is only meaningful together with services.omnigent.user.";
      }
      {
        assertion = !hasUri || uriIsSafe;
        message = "services.omnigent.database.uri is only accepted in a passwordless form (scheme://[user@][host[:port]][/db][?host|port|sslmode|sslrootcert|application_name|connect_timeout=...]); anything else could carry a secret into the Nix store, use database.uriFile.";
      }
      {
        assertion = badEnv == [ ];
        message = "services.omnigent.environment may not set module-controlled variables: ${lib.concatStringsSep ", " badEnv}.";
      }
      {
        assertion = cfg.environmentFile == null || !inStore cfg.environmentFile;
        message = "services.omnigent.environmentFile must be a runtime path outside the Nix store (secrets would be world-readable).";
      }
      {
        assertion = !hasUriFile || !inStore cfg.database.uriFile;
        message = "services.omnigent.database.uriFile must be a runtime path outside the Nix store (secrets would be world-readable).";
      }
    ];

    systemd.services.omnigent = {
      description = "Omnigent server";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      # Module-controlled values are exported by the start wrapper instead.
      inherit (cfg) environment;

      serviceConfig = {
        ExecStartPre = lib.optional (guardedFiles != [ ]) "+${guard} ${lib.escapeShellArgs guardedFiles}";
        ExecStart = start;
        Restart = "on-failure";
        RestartSec = "5s";

        StateDirectory = stateName;
        StateDirectoryMode = "0700";
        WorkingDirectory = cfg.stateDir;
        UMask = "0077";

        DynamicUser = cfg.user == null;
        User = lib.mkIf (cfg.user != null) cfg.user;
        Group = lib.mkIf (cfg.group != null) cfg.group;

        LoadCredential = lib.optional hasUriFile "database-uri:${toString cfg.database.uriFile}";
        EnvironmentFile = lib.optional (cfg.environmentFile != null) (toString cfg.environmentFile);

        # The server is a coordinator: it must never execute agent work or see
        # user files. (Hosts do that, elsewhere.)
        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
        ];
        RestrictNamespaces = true;
        LockPersonality = true;
        RestrictRealtime = true;
        SystemCallArchitectures = "native";
        CapabilityBoundingSet = "";
      };
    };
  };
}
