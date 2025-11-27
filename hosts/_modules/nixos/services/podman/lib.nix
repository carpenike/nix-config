{ pkgs
, lib
, config
, ...
}:
let
  cfg = config.modules.services.podman;
in
{
  _module.args.podmanLib = rec {
    # Helper to create a container with standard logging configuration and optional resource limits
    mkContainer = name: containerConfig:
      let
        defaults = {
          log-driver = cfg.containerDefaults.logDriver;
          extraOptions = [
            "--log-opt=tag=${cfg.containerDefaults.logTag}"
          ] ++ (containerConfig.extraOptions or [ ]);
        };
        # Add resource limits if specified in containerConfig
        withResourceLimits =
          if (containerConfig ? resources && containerConfig.resources != null)
          then defaults // {
            extraOptions = defaults.extraOptions ++
              (lib.optional (containerConfig.resources ? memory) "--memory=${containerConfig.resources.memory}") ++
              (lib.optional (containerConfig.resources ? memoryReservation) "--memory-reservation=${containerConfig.resources.memoryReservation}") ++
              (lib.optional (containerConfig.resources ? cpus) "--cpus=${containerConfig.resources.cpus}");
          }
          else defaults;
      in
      withResourceLimits // (builtins.removeAttrs containerConfig [ "resources" ]);

    # Helper to create logrotate configuration for a container's application logs
    # Note: This helper ONLY creates the logrotate configuration.
    # You must also call mkLogDirTmpfiles to ensure the log directory exists with
    # proper permissions before containers start.
    mkLogRotate =
      { containerName
      , logDir
      , user ? "999"
      , group ? "999"
      , postrotate ? "${pkgs.podman}/bin/podman kill --signal USR1 ${containerName} 2>/dev/null || true"
      , extraConfig ? { }
      }: {
        ${containerName} = cfg.containerDefaults.logRotationDefaults // {
          files = "${logDir}/*.log";
          su = "${user} ${group}";
          create = "0644 ${user} ${group}";
          inherit postrotate;
        } // extraConfig;
      };

    # Helper to ensure directory exists with proper permissions
    mkLogDirActivation =
      { name
      , path
      , user ? "999"
      , group ? "999"
      }: {
        "make${name}LogDir" = lib.stringAfter [ "var" ] ''
          mkdir -p "${path}"
          chown -R ${user}:${group} ${path}
        '';
      };

    # Helper to create tmpfiles rules for directories with correct ownership
    # Should be used in addition to mkLogDirActivation to ensure directories
    # exist with proper permissions at boot
    mkLogDirTmpfiles =
      { path
      , user ? "999"
      , group ? "999"
      }: [
        "d ${path} 0755 ${user} ${group} -"
      ];

    # Helper to create health check scripts for containerized services
    mkHealthCheck =
      { port
      , host ? "localhost"
      , protocol ? "https"
      , retries ? 60
      , delay ? 5
      , path ? ""
      }: ''
        echo "Waiting for service on ${host}:${toString port} to be ready..."
        for i in {1..${toString retries}}; do
          if ${pkgs.curl}/bin/curl -k -s -f --max-time 10 ${protocol}://${host}:${toString port}${path} >/dev/null 2>&1; then
            echo "Service is ready!"
            exit 0
          fi
          echo "Waiting for service... ($i/${toString retries})"
          sleep ${toString delay}
        done
        echo "Service failed to become ready after ${toString (retries * delay)} seconds."
        exit 1
      '';
  };
}
