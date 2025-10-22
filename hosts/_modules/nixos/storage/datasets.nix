{ lib, config, pkgs, ... }:
# Declarative ZFS dataset management for per-service isolation
#
# Architecture:
# - Single-disk hosts: Service datasets under rpool/safe/persist (default)
# - Multi-disk hosts: Service datasets under dedicated pool (e.g., tank/services)
#
# The parent dataset acts as a logical container (mountpoint=none recommended)
# Individual service datasets mount to standard FHS paths (e.g., /var/lib/postgresql)
let
  cfg = config.modules.storage.datasets;

  # Shell escaping helper for safe interpolation
  escape = lib.escapeShellArg;

  # Type validation for ZFS properties
  zfsRecordsizeType = lib.types.addCheck lib.types.str (
    str: builtins.match "[0-9]+[KMGTP]" str != null
  ) // {
    description = "ZFS recordsize (e.g., 8K, 16K, 128K, 1M)";
  };
in
{
  options.modules.storage.datasets = {
    enable = lib.mkEnableOption "declarative ZFS dataset management";

    parentDataset = lib.mkOption {
      type = lib.types.str;
      default = "rpool/safe/persist";
      description = ''
        The parent ZFS dataset for service data.
        Defaults to rpool/safe/persist for single-disk systems.
        Multi-disk hosts should override to use their data pool (e.g., tank/services).
      '';
      example = "tank/services";
    };

    parentMount = lib.mkOption {
      type = lib.types.str;
      default = "/srv";
      description = ''
        A default base path for service mounts.
        Service datasets will be mounted to ''${parentMount}/<serviceName>
        unless a specific `mountpoint` is provided for the service, which is the
        recommended approach for mounting to standard FHS locations (e.g. /var/lib/postgresql).
      '';
    };

    services = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          recordsize = lib.mkOption {
            type = zfsRecordsizeType;
            default = "128K";
            description = ''
              ZFS recordsize property. Must be a power of 2 between 512 and 1M.
              Recommended values:
              - 8K: PostgreSQL data
              - 16K: Small files, SQLite databases (Sonarr, Radarr)
              - 128K: Default, general purpose
              - 1M: Large files, media caches (Plex)
            '';
          };

          compression = lib.mkOption {
            type = lib.types.enum [ "on" "off" "lz4" "lzjb" "gzip" "gzip-1" "gzip-2" "gzip-3" "gzip-4" "gzip-5" "gzip-6" "gzip-7" "gzip-8" "gzip-9" "zstd" "zstd-fast" "zle" ];
            default = "lz4";
            description = ''
              ZFS compression algorithm.
              Recommended: lz4 (fast, good ratio), zstd (better ratio, more CPU)
            '';
          };

          properties = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            default = {};
            description = ''
              Additional ZFS properties to set on the dataset.
              Example: { "com.sun:auto-snapshot" = "true"; logbias = "latency"; }
            '';
          };

          mountpoint = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = ''
              Override the mountpoint for this dataset.
              If null (default), auto-calculated as parentMount/serviceName.
              Set to "none" to disable mounting.
              Set to "legacy" to use fileSystems declaration instead.
            '';
          };

          owner = lib.mkOption {
            type = lib.types.str;
            default = "root";
            description = ''
              User to own the mountpoint directory.
              Only applies when mountpoint is not "none" or "legacy".
            '';
          };

          group = lib.mkOption {
            type = lib.types.str;
            default = "root";
            description = ''
              Group to own the mountpoint directory.
              Only applies when mountpoint is not "none" or "legacy".
            '';
          };

          mode = lib.mkOption {
            type = lib.types.str;
            default = "0755";
            description = ''
              Permission mode for the mountpoint directory.
              Only applies when mountpoint is not "none" or "legacy".
            '';
          };
        };
      });
      default = {};
      description = ''
        Service-specific dataset configurations.
        Each service declares its storage requirements here.
      '';
      example = lib.literalExpression ''
        {
          sonarr = {
            recordsize = "16K";
            compression = "lz4";
            properties = {
              "com.sun:auto-snapshot" = "true";
            };
          };
          plex = {
            recordsize = "1M";
            compression = "lz4";
            properties = {
              "com.sun:auto-snapshot" = "false";
            };
          };
        }
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Create datasets via activation script
    # This runs after pool import but before services start
    system.activationScripts.zfs-service-datasets = {
      # Run after special filesystems are mounted AND all ZFS pools are imported
      deps = [ "specialfs" "zfs-import.target" ];

      text = ''
        set -euo pipefail
        IFS=$'\n\t'

        echo "=== ZFS Service Datasets Activation ==="

        # Wait up to 30 seconds for the parent pool to be imported
        # This prevents race conditions during boot
        PARENT_POOL=$(echo "${escape cfg.parentDataset}" | ${pkgs.gawk}/bin/awk -F/ '{print $1}')
        for i in $(seq 1 30); do
          if ${pkgs.zfs}/bin/zfs list -H -o name "$PARENT_POOL" >/dev/null 2>&1; then
            echo "Parent pool '$PARENT_POOL' is available."
            break
          fi
          echo "Waiting for parent pool '$PARENT_POOL' to be imported... ($i/30)"
          sleep 1
          if [ "$i" -eq 30 ]; then
            echo "ERROR: Parent pool '$PARENT_POOL' not available after 30 seconds."
            exit 1
          fi
        done

        # Ensure parent dataset exists (self-healing)
        # Create it if missing instead of failing boot
        if ! ${pkgs.zfs}/bin/zfs list -H ${escape cfg.parentDataset} >/dev/null 2>&1; then
          echo "WARNING: Parent dataset ${cfg.parentDataset} does not exist. Creating it now..."
          # Use -p to create intermediate datasets, set mountpoint=none for logical container
          if ${pkgs.zfs}/bin/zfs create -p -o mountpoint=none ${escape cfg.parentDataset}; then
            echo "  ✓ Created parent dataset successfully."
          else
            echo "  ✗ CRITICAL: Failed to create parent dataset ${cfg.parentDataset}."
            exit 1
          fi
        fi

        ${lib.concatStringsSep "\n" (lib.mapAttrsToList (serviceName: serviceConfig:
          let
            datasetPath = "${cfg.parentDataset}/${serviceName}";
            mountpoint = if serviceConfig.mountpoint != null
                        then serviceConfig.mountpoint
                        else "${cfg.parentMount}/${serviceName}";

            # Merge all properties (recordsize, compression, custom)
            allProperties = lib.mergeAttrs {
              inherit (serviceConfig) recordsize compression;
              mountpoint = mountpoint;
            } serviceConfig.properties;
          in ''
            # --- Service: ${serviceName} ---

            # Check if dataset already exists
            if ${pkgs.zfs}/bin/zfs list -H ${escape datasetPath} >/dev/null 2>&1; then
              echo "Dataset exists: ${datasetPath}"
            else
              echo "Creating dataset: ${datasetPath}"
              if ${pkgs.zfs}/bin/zfs create -p ${escape datasetPath}; then
                echo "  ✓ Created successfully"
              else
                echo "  ✗ Failed to create dataset ${datasetPath}"
                exit 1
              fi
            fi

            # Set/update properties (idempotent)
            echo "Configuring properties for ${datasetPath}:"
            ${lib.concatStringsSep "\n" (lib.mapAttrsToList (prop: value: ''
              # Get current value (allow stderr for debugging, use '-' as default for unset properties)
              CURRENT_VALUE=$(${pkgs.zfs}/bin/zfs get -H -o value ${escape prop} ${escape datasetPath} || echo "-")

              # Compare with desired value (unescaped)
              if [ "$CURRENT_VALUE" != ${escape value} ]; then
                echo "  Setting property: ${prop}=${value}"
                # The 'property=value' pair must be a single argument to 'zfs set'
                if ${pkgs.zfs}/bin/zfs set ${escape "${prop}=${value}"} ${escape datasetPath}; then
                  echo "    ✓ Property set successfully"
                else
                  echo "    ✗ Failed to set property (this may be expected for read-only properties)"
                fi
              else
                echo "  ✓ Property is already set: ${prop}=${value}"
              fi
            '') allProperties)}

            # Ensure mount directory exists if needed
            ${lib.optionalString (mountpoint != "none" && mountpoint != "legacy") ''
              if [ ! -d "${mountpoint}" ]; then
                echo "Creating mount directory: ${mountpoint}"
                mkdir -p "${mountpoint}"
              fi
            ''}

            echo ""
          ''
        ) cfg.services)}

        echo "=== ZFS Service Datasets Activation Complete ==="
      '';
    };

    # Generate tmpfiles rules to ensure directories exist with correct permissions
    # This runs after datasets are created and mounted
    systemd.tmpfiles.rules = lib.flatten (lib.mapAttrsToList (serviceName: serviceConfig:
      let
        mountpoint = if serviceConfig.mountpoint != null
                    then serviceConfig.mountpoint
                    else "${cfg.parentMount}/${serviceName}";
      in
        # Only create tmpfiles entry if it's a real mountpoint (not "none" or "legacy")
        lib.optional (mountpoint != "none" && mountpoint != "legacy")
          "d \"${mountpoint}\" ${serviceConfig.mode} ${serviceConfig.owner} ${serviceConfig.group} - -"
    ) cfg.services);

    # Add assertions to validate configuration
    assertions = [
      {
        assertion = cfg.enable -> (cfg.parentDataset != "");
        message = "modules.storage.datasets.parentDataset must be set when enabled";
      }
      {
        assertion = cfg.enable -> (cfg.parentMount != "");
        message = "modules.storage.datasets.parentMount must be set when enabled";
      }
      {
        assertion = cfg.enable -> (lib.hasPrefix "/" cfg.parentMount);
        message = "modules.storage.datasets.parentMount must be an absolute path starting with /";
      }
      {
        assertion = cfg.enable -> (lib.all (s:
          s.mountpoint == null ||
          s.mountpoint == "none" ||
          s.mountpoint == "legacy" ||
          lib.hasPrefix "/" s.mountpoint
        ) (lib.attrValues cfg.services));
        message = "All service mountpoints must be absolute paths (starting with /), 'none', 'legacy', or null";
      }
    ];
  };
}
