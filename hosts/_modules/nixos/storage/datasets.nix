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
            default = "0750";
            description = ''
              Permission mode for the mountpoint directory.
              Defaults to 0750 to allow group read access for backup systems.
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

    utility = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          recordsize = lib.mkOption {
            type = zfsRecordsizeType;
            default = "128K";
            description = "ZFS recordsize property";
          };

          compression = lib.mkOption {
            type = lib.types.enum [ "on" "off" "lz4" "lzjb" "gzip" "gzip-1" "gzip-2" "gzip-3" "gzip-4" "gzip-5" "gzip-6" "gzip-7" "gzip-8" "gzip-9" "zstd" "zstd-fast" "zle" ];
            default = "lz4";
            description = "ZFS compression algorithm";
          };

          properties = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            default = {};
            description = "Additional ZFS properties";
          };

          mountpoint = lib.mkOption {
            type = lib.types.str;
            default = "none";
            description = ''
              Mountpoint for this utility dataset.
              Typically "none" for utility datasets used as parent containers.
            '';
          };

          owner = lib.mkOption {
            type = lib.types.str;
            default = "root";
            description = "User to own the mountpoint directory (if not 'none')";
          };

          group = lib.mkOption {
            type = lib.types.str;
            default = "root";
            description = "Group to own the mountpoint directory (if not 'none')";
          };

          mode = lib.mkOption {
            type = lib.types.str;
            default = "0750";
            description = "Permission mode for the mountpoint directory (if not 'none')";
          };
        };
      });
      default = {};
      description = ''
        Utility datasets with absolute paths (not under parentDataset).
        Use this for datasets like tank/temp that are siblings to parentDataset.
        Keys should be the full ZFS path (e.g., "tank/temp").
      '';
      example = lib.literalExpression ''
        {
          "tank/temp" = {
            mountpoint = "none";
            properties = {
              "com.sun:auto-snapshot" = "false";
            };
          };
        }
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Create datasets via systemd service
    # This runs after ZFS pool import (zfs-import.target) but before services need them
    systemd.services.zfs-service-datasets = {
      description = "Create ZFS datasets for service isolation";
      wantedBy = [ "multi-user.target" ];
      after = [ "zfs-import.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };

      path = with pkgs; [ zfs gawk coreutils ];

      script = ''
        set -euo pipefail
        IFS=$'\n\t'

        echo "=== ZFS Service Datasets Setup ==="

        # No polling needed - systemd guarantees pools are imported
        PARENT_POOL=$(echo "${escape cfg.parentDataset}" | awk -F/ '{print $1}')
        echo "Parent pool '$PARENT_POOL' is available (guaranteed by zfs-import.target)."

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

        # Process utility datasets first (they may be parents of service datasets)
        ${lib.concatStringsSep "\n" (lib.mapAttrsToList (datasetPath: datasetConfig:
          let
            mountpoint = datasetConfig.mountpoint;
            allProperties = lib.mergeAttrs {
              inherit (datasetConfig) recordsize compression;
              mountpoint = mountpoint;
            } datasetConfig.properties;
          in ''
            # --- Utility Dataset: ${datasetPath} ---

            if ${pkgs.zfs}/bin/zfs list -H ${escape datasetPath} >/dev/null 2>&1; then
              echo "Utility dataset exists: ${datasetPath}"
            else
              echo "Creating utility dataset: ${datasetPath}"
              if ${pkgs.zfs}/bin/zfs create -p ${escape datasetPath}; then
                echo "  ✓ Created successfully"
              else
                echo "  ✗ Failed to create dataset ${datasetPath}"
                exit 1
              fi
            fi

            echo "Configuring properties for ${datasetPath}:"
            ${lib.concatStringsSep "\n" (lib.mapAttrsToList (prop: value: ''
              CURRENT_VALUE=$(${pkgs.zfs}/bin/zfs get -H -o value ${escape prop} ${escape datasetPath})
              if [ "$CURRENT_VALUE" != "${value}" ]; then
                echo "  Setting property: ${prop}=${value}"
                if ${pkgs.zfs}/bin/zfs set ${escape "${prop}=${value}"} ${escape datasetPath}; then
                  echo "    ✓ Property set successfully"
                else
                  echo "    ✗ Failed to set property"
                fi
              else
                echo "  ✓ Property is already set: ${prop}=${value}"
              fi
            '') allProperties)}

            ${lib.optionalString (mountpoint != "none" && mountpoint != "legacy") ''
              if [ ! -d "${mountpoint}" ]; then
                echo "Creating mount directory: ${mountpoint}"
                mkdir -p "${mountpoint}"
              fi
            ''}

            echo ""
          ''
        ) cfg.utility)}

        # Process service datasets under parentDataset
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
              # Get current value - let script fail immediately if zfs get fails (pool offline, dataset missing, etc.)
              # ZFS naturally returns inherited values or '-' for unset properties
              # NOTE: String comparison works for most properties. For numeric properties, could use 'zfs get -H -p'
              # for parseable format, but current approach is acceptable given ZFS's stable output format.
              CURRENT_VALUE=$(${pkgs.zfs}/bin/zfs get -H -o value ${escape prop} ${escape datasetPath})

              # Compare with desired value (unescaped) to avoid false mismatches
              if [ "$CURRENT_VALUE" != "${value}" ]; then
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

        echo "=== ZFS Service Datasets Setup Complete ==="
      '';
    };

    # Generate tmpfiles rules to ensure directories exist
    # For native systemd services: Permissions are managed by StateDirectoryMode
    # For OCI containers: Permissions are managed via tmpfiles (they don't support StateDirectory)
    systemd.tmpfiles.rules = lib.flatten (
      # Service datasets
      (lib.mapAttrsToList (serviceName: serviceConfig:
        let
          mountpoint = if serviceConfig.mountpoint != null
                      then serviceConfig.mountpoint
                      else "${cfg.parentMount}/${serviceName}";
          hasExplicitPermissions = (serviceConfig.mode or null) != null
                                 && (serviceConfig.owner or null) != null
                                 && (serviceConfig.group or null) != null;
        in
          if (mountpoint != "none" && mountpoint != "legacy") then (
            if hasExplicitPermissions then [
              "d \"${mountpoint}\" ${serviceConfig.mode} ${serviceConfig.owner} ${serviceConfig.group} - -"
              "z \"${mountpoint}\" ${serviceConfig.mode} ${serviceConfig.owner} ${serviceConfig.group} - -"
            ] else []
          ) else []
      ) cfg.services)
      ++
      # Utility datasets
      (lib.mapAttrsToList (datasetPath: datasetConfig:
        let
          mountpoint = datasetConfig.mountpoint;
          hasExplicitPermissions = (datasetConfig.mode or null) != null
                                 && (datasetConfig.owner or null) != null
                                 && (datasetConfig.group or null) != null;
        in
          if (mountpoint != "none" && mountpoint != "legacy") then (
            if hasExplicitPermissions then [
              "d \"${mountpoint}\" ${datasetConfig.mode} ${datasetConfig.owner} ${datasetConfig.group} - -"
              "z \"${mountpoint}\" ${datasetConfig.mode} ${datasetConfig.owner} ${datasetConfig.group} - -"
            ] else []
          ) else []
      ) cfg.utility)
    );

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
