# IT-Tools - Collection of useful web-based developer utilities
#
# IT-Tools provides 45+ web-based tools for developers including:
# - UUID generators, Base64 encoders, JWT parsers
# - Password generators, QR code generators
# - Color converters, hash generators, and more
#
# This service is completely stateless - no persistent data required.
# All tools run client-side in the browser. Backup and failure
# notifications are therefore disabled by default (see extraOptions
# overrides below); the factory-standard ZFS dataset remains unused by
# the container (no config volume is mounted).
#
# Factory-based implementation (mylib.mkContainerService).
#
# Usage:
#   modules.services.it-tools = {
#     enable = true;
#     reverseProxy = {
#       enable = true;
#       hostName = "it-tools.holthome.net";
#     };
#   };

{ lib
, mylib
, pkgs
, config
, podmanLib
, ...
}:

mylib.mkContainerService {
  inherit lib mylib pkgs config podmanLib;

  name = "it-tools";
  description = "IT-Tools - web-based developer utilities collection";

  spec = {
    description = "IT-Tools - web-based developer utilities collection";
    port = 8380;
    containerPort = 8080; # home-operations IT-Tools image listens on port 8080
    image = "ghcr.io/home-operations/it-tools:2024.10.22";
    category = "productivity";
    displayName = "IT-Tools";
    function = "developer_utilities";

    # Completely stateless - do not mount the data directory into the container
    skipDefaultConfigMount = true;

    # Image lacks curl; use wget for the health probe (containerPort 8080)
    healthCommand = "wget --no-verbose --tries=1 --spider http://127.0.0.1:8080/ || exit 1";
    # IT-Tools serves static content and starts quickly
    startPeriod = "10s";

    # Lightweight static content server
    resources = {
      memory = "128M";
      memoryReservation = "64M";
      cpus = "0.5";
    };
  };

  extraOptions = {
    # Stateless service: keep the pre-factory behavior of no backup job.
    # (Overrides the factory default, which enables backups.)
    backup = lib.mkOption {
      type = lib.types.nullOr mylib.types.backupSubmodule;
      default = null;
      description = "Backup configuration. Disabled: IT-Tools holds no state worth backing up.";
    };

    # No failure notifications pre-factory; keep that behavior.
    notifications = lib.mkOption {
      type = lib.types.nullOr mylib.types.notificationSubmodule;
      default = null;
      description = "Notification configuration. Disabled by default for this stateless service.";
    };
  };
}
