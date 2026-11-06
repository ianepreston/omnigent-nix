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
  # `scheme://user:password@host/...`
  uriHasPassword = hasUri && builtins.match ".*://[^/@:]+:[^/@]+@.*" cfg.database.uri != null;
  databaseSources = lib.count (x: x) [
    hasUri
    hasUriFile
    cfg.database.sqlite.enable
  ];

  bracketed =
    if lib.hasInfix ":" cfg.listen.address then "[${cfg.listen.address}]" else cfg.listen.address;

  # Reads secrets from systemd credentials at start so nothing secret is ever
  # a Nix value, a unit `Environment=` line, or a store path.
  start = pkgs.writeShellScript "omnigent-server-start" ''
    set -eu
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
      description = "Extra non-secret environment variables for the service.";
    };

    environmentFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
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
        type = lib.types.nullOr lib.types.path;
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
          Literal database URI. Discouraged: it becomes a store path. Only for a
          URI that carries no secret (for example a peer-authenticated socket).
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
    ];

    warnings = lib.optional (hasUri && uriHasPassword) ''
      services.omnigent.database.uri is a Nix value and will be world-readable in
      the store. Use database.uriFile unless the URI contains no secret.
    '';

    systemd.services.omnigent = {
      description = "Omnigent server";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      environment = {
        HOST = cfg.listen.address;
        PORT = toString cfg.listen.port;
        ARTIFACT_DIR = "${cfg.stateDir}/artifacts";
        OMNIGENT_CONFIG = "${settingsFile}";
        OMNIGENT_MANAGED_BY_NIX = "1";
        OMNIGENT_NO_UPDATE_CHECK = "1";
        HOME = cfg.stateDir;
      }
      // lib.optionalAttrs (cfg.auth.provider != null) { OMNIGENT_AUTH_PROVIDER = cfg.auth.provider; }
      // lib.optionalAttrs (cfg.publicUrl != null) { OMNIGENT_ACCOUNTS_BASE_URL = cfg.publicUrl; }
      // lib.optionalAttrs hasUri { DATABASE_URL = cfg.database.uri; }
      // lib.optionalAttrs cfg.database.sqlite.enable {
        DATABASE_URL = "sqlite:///${cfg.stateDir}/omnigent.db";
      }
      // cfg.environment;

      serviceConfig = {
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
