# Opt-in adapter that creates a database and role on an *existing* upstream
# NixOS PostgreSQL service and points the Omnigent server at it over a unix
# socket with peer authentication. It does not touch `pg_hba.conf`, the
# PostgreSQL package/version, or generate passwords, and it never assumes it is
# the only PostgreSQL consumer.
#
# Peer authentication needs a fixed service user whose name equals the role, so
# this adapter sets `services.omnigent.user`.
{ config, lib, ... }:
let
  cfg = config.services.omnigent.postgresql;
  server = config.services.omnigent;
in
{
  options.services.omnigent.postgresql = {
    createLocally = lib.mkEnableOption "an Omnigent database and role in the local NixOS PostgreSQL service";

    name = lib.mkOption {
      type = lib.types.str;
      default = "omnigent";
      description = "Database and role name (also the service user, for peer authentication).";
    };
  };

  config = lib.mkIf (server.enable && cfg.createLocally) {
    assertions = [
      {
        assertion = config.services.postgresql.enable;
        message = "services.omnigent.postgresql.createLocally needs services.postgresql.enable = true (this adapter does not enable it).";
      }
    ];

    services.postgresql = {
      ensureDatabases = [ cfg.name ];
      ensureUsers = [
        {
          name = cfg.name;
          ensureDBOwnership = true;
        }
      ];
    };

    users.users.${cfg.name} = {
      isSystemUser = true;
      group = cfg.name;
    };
    users.groups.${cfg.name} = { };

    services.omnigent = {
      user = cfg.name;
      group = cfg.name;
      database.uri = lib.mkDefault "postgresql+psycopg://${cfg.name}@/${cfg.name}?host=/run/postgresql";
    };

    systemd.services.omnigent = {
      after = [ "postgresql.target" ];
      requires = [ "postgresql.target" ];
    };
  };
}
