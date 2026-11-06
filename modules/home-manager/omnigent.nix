# Home Manager module with two independent trees: a host (executes agent work)
# and a desktop client. Installing either starts nothing; a host daemon exists
# only when `host.autoStart` is explicitly enabled.
{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.omnigent;
  system = pkgs.stdenv.hostPlatform.system;
  selfPkgs = self.packages.${system};

  harnessPackage = {
    codex = pkgs.codex;
    claude-code = pkgs.claude-code;
    opencode = pkgs.opencode;
    goose = pkgs.goose-cli;
  };
  enabledHarnesses = lib.filterAttrs (_: h: h.enable) cfg.host.harnesses;

  hostPackage =
    if cfg.host.package ? override then
      cfg.host.package.override {
        harnessPackages = lib.mapAttrsToList (name: _: harnessPackage.${name}) enabledHarnesses;
        extraPackages = cfg.host.extraPackages;
      }
    else
      cfg.host.package;

  hostArgs = [
    "host"
    "--server"
    cfg.host.serverUrl
    "--non-interactive"
  ];
in
{
  options.programs.omnigent = {
    host = {
      enable = lib.mkEnableOption "the Omnigent host tools (does not start a daemon)";

      package = lib.mkOption {
        type = lib.types.package;
        default = selfPkgs.omnigent-host;
        defaultText = lib.literalExpression "omnigent.packages.\${system}.omnigent-host";
        description = "Base host package; harness packages are layered onto it.";
      };

      serverUrl = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "https://omnigent.example.net";
        description = ''
          Explicit, non-secret server URL for `omnigent host --server`. Never
          selected implicitly from a desktop setting or the environment.
        '';
      };

      autoStart = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Start the host as a user service (systemd on Linux, LaunchAgent on
          macOS). A host can run arbitrary agent work with this user's files,
          network and credentials: enabling this is an explicit decision.
        '';
      };

      harnesses = lib.genAttrs [ "codex" "claude-code" "opencode" "goose" ] (name: {
        enable = lib.mkEnableOption "the ${name} harness on the host's PATH" // {
          default = name == "codex";
        };
      });

      extraPackages = lib.mkOption {
        type = lib.types.listOf lib.types.package;
        default = [ ];
        description = "Additional tools to put on the host's PATH (for harnesses provided outside this flake).";
      };
    };

    desktop = {
      enable = lib.mkEnableOption "the Omnigent desktop client (usable without the host)";

      package = lib.mkOption {
        type = lib.types.nullOr lib.types.package;
        default = selfPkgs.omnigent-desktop or null;
        defaultText = lib.literalExpression "omnigent.packages.\${system}.omnigent-desktop";
        description = "Desktop package. Not yet provided on every platform.";
      };
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.host.enable {
      assertions = [
        {
          assertion = !cfg.host.autoStart || cfg.host.serverUrl != null;
          message = "programs.omnigent.host.autoStart needs programs.omnigent.host.serverUrl.";
        }
      ];

      home.packages = [ hostPackage ];

      systemd.user.services.omnigent-host =
        lib.mkIf (cfg.host.autoStart && pkgs.stdenv.hostPlatform.isLinux)
          {
            Unit = {
              Description = "Omnigent host";
              After = [ "network-online.target" ];
            };
            Service = {
              ExecStart = lib.escapeShellArgs ([ "${hostPackage}/bin/omnigent" ] ++ hostArgs);
              Restart = "on-failure";
              RestartSec = "10s";
              Environment = [ "OMNIGENT_MANAGED_BY_NIX=1" ];
            };
            Install.WantedBy = [ "default.target" ];
          };

      launchd.agents.omnigent-host = lib.mkIf (cfg.host.autoStart && pkgs.stdenv.hostPlatform.isDarwin) {
        enable = true;
        config = {
          ProgramArguments = [ "${hostPackage}/bin/omnigent" ] ++ hostArgs;
          RunAtLoad = true;
          KeepAlive = true;
          EnvironmentVariables.OMNIGENT_MANAGED_BY_NIX = "1";
        };
      };
    })

    (lib.mkIf cfg.desktop.enable {
      assertions = [
        {
          assertion = cfg.desktop.package != null;
          message = "programs.omnigent.desktop: the Omnigent desktop package is intentionally Linux-only in this flake (no package for ${system}). Use the browser UI, or set programs.omnigent.desktop.package yourself.";
        }
      ];
      home.packages = lib.optional (cfg.desktop.package != null) cfg.desktop.package;
    })
  ];
}
