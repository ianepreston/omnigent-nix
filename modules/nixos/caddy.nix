# Opt-in adapter for stock `services.caddy.virtualHosts`. Not a dependency of
# the core module: import it only if you use upstream NixOS Caddy and accept
# this ownership model. It never exposes the service merely because
# `services.omnigent.enable` is true.
{ config, lib, ... }:
let
  cfg = config.services.omnigent.caddy;
  server = config.services.omnigent;
in
{
  options.services.omnigent.caddy = {
    enable = lib.mkEnableOption "a stock-NixOS Caddy virtual host in front of the Omnigent listener";

    hostName = lib.mkOption {
      type = lib.types.str;
      example = "omnigent.example.net";
      description = "Virtual host name. DNS, certificates and global options are the consumer's.";
    };

    extraConfig = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Extra Caddyfile directives for the vhost (authentication, headers, …).";
    };
  };

  config = lib.mkIf (server.enable && cfg.enable) {
    assertions = [
      {
        assertion = server.publicUrl != null && lib.hasSuffix "://${cfg.hostName}" server.publicUrl;
        message = ''
          services.omnigent.caddy.hostName (${cfg.hostName}) must match
          services.omnigent.publicUrl (${toString server.publicUrl}); both name the same origin.
        '';
      }
    ];

    # Caddy speaks HTTP/2 to clients by default, which the UI's long-lived
    # streaming connections rely on. A zero flush interval keeps SSE unbuffered.
    services.caddy.virtualHosts.${cfg.hostName}.extraConfig = ''
      reverse_proxy ${server.listenUrl} {
        flush_interval -1
      }
      ${cfg.extraConfig}
    '';
  };
}
