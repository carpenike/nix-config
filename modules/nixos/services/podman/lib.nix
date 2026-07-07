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
    # Helper to create a container with standard logging configuration, hardening
    # defaults, and optional resource limits.
    #
    # Recognized hardening attrs (stripped before passing to oci-containers):
    #   allowPrivilegeEscalation = true;   # opt out of no-new-privileges
    #   dropAllCapabilities = true/false;  # force/suppress --cap-drop=ALL
    #   capAdd = [ "NET_RAW" ];            # add back individual capabilities
    mkContainer = _name: containerConfig:
      let
        userExtraOptions = containerConfig.extraOptions or [ ];

        # --- Container hardening defaults --------------------------------
        # Podman on this fleet is rootful, so a container escape is root on
        # the host. Two cheap mitigations are applied by default:
        #
        # 1. --security-opt=no-new-privileges — blocks privilege gains across
        #    execve (setuid binaries, file capabilities). Safe for root
        #    entrypoints that *drop* privileges (gosu/su-exec/s6-setuidgid
        #    use plain setuid() syscalls, which NNP does not affect). Opt out
        #    with `allowPrivilegeEscalation = true` only for images whose
        #    non-root user genuinely needs sudo/setuid at runtime.
        #
        # 2. --cap-drop=ALL — applied by default ONLY when the container runs
        #    as a non-root user (detected via a --user= flag or the `user`
        #    attr, or forced with `dropAllCapabilities = true`). Non-root
        #    processes have no effective capabilities anyway, so this merely
        #    shrinks the bounding set. Root containers keep podman's default
        #    capability set: LinuxServer-style entrypoints chown files and
        #    setuid to PUID/PGID at startup (CAP_CHOWN, CAP_SETUID,
        #    CAP_SETGID, CAP_FOWNER, CAP_DAC_OVERRIDE, ...) and dropping ALL
        #    would break that first-boot path. Add back individual caps for
        #    non-root containers with `capAdd`.
        #
        # Both are skipped for --privileged containers and when the consumer
        # already passes its own conflicting flag.
        isPrivileged = lib.elem "--privileged" userExtraOptions;
        hasExplicitNNP = lib.any (opt: lib.hasPrefix "--security-opt=no-new-privileges" opt) userExtraOptions;
        hasExplicitCapDrop = lib.any (opt: lib.hasPrefix "--cap-drop" opt) userExtraOptions;
        runsAsNonRoot =
          (containerConfig.user or null) != null
          || lib.any (opt: lib.hasPrefix "--user=" opt) userExtraOptions;
        allowPrivilegeEscalation = containerConfig.allowPrivilegeEscalation or false;
        dropAllCapabilities = containerConfig.dropAllCapabilities or runsAsNonRoot;
        capAdd = containerConfig.capAdd or [ ];
        hardeningOptions =
          lib.optional (!allowPrivilegeEscalation && !isPrivileged && !hasExplicitNNP)
            "--security-opt=no-new-privileges"
          ++ lib.optional (dropAllCapabilities && !isPrivileged && !hasExplicitCapDrop)
            "--cap-drop=ALL"
          ++ map (cap: "--cap-add=${cap}") capAdd;

        defaults = {
          log-driver = cfg.containerDefaults.logDriver;
          extraOptions = [
            "--log-opt=tag=${cfg.containerDefaults.logTag}"
          ] ++ userExtraOptions ++ hardeningOptions;
        };
        # Add resource limits if specified in containerConfig
        # Supports: memory, memoryReservation, cpus
        # Note: cpuQuota is NOT supported because podman's --cpu-quota expects microseconds,
        # not percentage. Use cpus (e.g., "0.5" for 50% of one core) instead.
        resources = containerConfig.resources or null;
        withResourceLimits =
          if (resources != null)
          then defaults // {
            extraOptions = defaults.extraOptions ++
              (lib.optional (resources.memory or null != null) "--memory=${resources.memory}") ++
              (lib.optional (resources.memoryReservation or null != null) "--memory-reservation=${resources.memoryReservation}") ++
              (lib.optional (resources.cpus or null != null) "--cpus=${resources.cpus}");
          }
          else defaults;
      in
      # Remove helper-only attrs ("resources", "extraOptions", hardening knobs) from
        # containerConfig so they don't overwrite the merged extraOptions (logging,
        # hardening, resource limits) or leak unknown attrs into oci-containers.
      withResourceLimits // (builtins.removeAttrs containerConfig [
        "resources"
        "extraOptions"
        "allowPrivilegeEscalation"
        "dropAllCapabilities"
        "capAdd"
      ]);

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
