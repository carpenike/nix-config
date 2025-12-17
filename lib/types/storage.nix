# ZFS dataset configuration type definition
{ lib }:
let
  inherit (lib) types mkOption;
in
{
  # Standardized ZFS dataset configuration submodule
  # Services with persistent data should use this type for consistent ZFS dataset management
  datasetSubmodule = types.submodule {
    options = {
      recordsize = mkOption {
        type = types.str;
        default = "128K";
        description = ''
          ZFS recordsize property. Must be a power of 2 between 512 and 1M.
          Recommended values:
          - 8K: PostgreSQL data
          - 16K: Small files, SQLite databases (Sonarr, Radarr)
          - 128K: Default, general purpose
          - 1M: Large files, media caches (Plex)
        '';
        example = "16K";
      };

      compression = mkOption {
        type = types.enum [ "on" "off" "lz4" "zstd" "gzip" "zle" ];
        default = "lz4";
        description = "ZFS compression algorithm";
      };

      properties = mkOption {
        type = types.attrsOf types.str;
        default = { };
        description = "Additional ZFS properties to set on the dataset";
        example = {
          "com.sun:auto-snapshot" = "true";
          logbias = "latency";
        };
      };

      mountpoint = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Override the mountpoint for this dataset.
          If null, uses the service's dataDir.
        '';
      };

      owner = mkOption {
        type = types.str;
        default = "root";
        description = "User to own the mountpoint directory";
      };

      group = mkOption {
        type = types.str;
        default = "root";
        description = "Group to own the mountpoint directory";
      };

      mode = mkOption {
        type = types.str;
        default = "0755";
        description = "Permissions mode for the mountpoint directory";
      };
    };
  };
}
