# Optional OCI image for provider-created (managed-sandbox) hosts. Built from
# `omnigent-host`; contains no credentials.
{
  lib,
  dockerTools,
  omnigent-host,
  bashInteractive,
  coreutils,
  findutils,
  gnugrep,
  gnused,
  gnutar,
  gzip,
  curl,
  cacert,
  openssh,
}:
dockerTools.buildLayeredImage {
  name = "omnigent-runner";
  tag = omnigent-host.version;
  contents = [
    omnigent-host
    bashInteractive
    coreutils
    findutils
    gnugrep
    gnused
    gnutar
    gzip
    curl
    cacert
    openssh
    dockerTools.binSh
    dockerTools.usrBinEnv
    dockerTools.fakeNss
  ];
  extraCommands = ''
    mkdir -p tmp home/runner workspace
    chmod 1777 tmp
  '';
  config = {
    Entrypoint = [ "${omnigent-host}/bin/omnigent" ];
    Cmd = [ "--help" ];
    User = "65532:65532";
    WorkingDir = "/workspace";
    Env = [
      "HOME=/home/runner"
      "SSL_CERT_FILE=${cacert}/etc/ssl/certs/ca-bundle.crt"
      "OMNIGENT_MANAGED_BY_NIX=1"
    ];
  };
}
