{
  pkgs,
  lib,
  config,
  ...
}:
let
  cfg = config.modules.services.podman;
in
{
  _module.args.podmanLib = rec {
    # Helper to create a container with standard logging configuration
    mkContainer = name: containerConfig:
      let
        defaults = {
          log-driver = cfg.containerDefaults.logDriver;
          extraOptions = [
            "--log-opt=tag=${cfg.containerDefaults.logTag}"
          ] ++ (containerConfig.extraOptions or []);
        };
      in
      defaults // containerConfig;

    # Helper to create logrotate configuration for a container's application logs
    mkLogRotate = {
      containerName,
      logDir,
      user ? "999",
      group ? "999",
      postrotate ? "${pkgs.podman}/bin/podman kill --signal USR1 ${containerName} 2>/dev/null || true",
      extraConfig ? {}
    }: {
      ${containerName} = cfg.containerDefaults.logRotationDefaults // {
        files = "${logDir}/*.log";
        su = "${user} ${group}";
        create = "0644 ${user} ${group}";
        inherit postrotate;
      } // extraConfig;
    };

    # Helper to ensure directory exists with proper permissions
    mkLogDirActivation = {
      name,
      path,
      user ? "999",
      group ? "999"
    }: {
      "make${name}LogDir" = lib.stringAfter [ "var" ] ''
        mkdir -p "${path}"
        chown -R ${user}:${group} ${path}
      '';
    };
  };
}
