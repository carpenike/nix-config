{ config, ... }:
# Dispatcharr Configuration for forge
#
# IPTV stream management service
# See: https://github.com/Dispatcharr/Dispatcharr
#
# Architecture:
# - Uses shared PostgreSQL instance (main) instead of embedded database
# - Database provisioned declaratively via PostgreSQL module
# - ZFS dataset for application data
# - Backup integration via restic
# - Health monitoring and notifications
{
  config = {
    # Declare database requirements for dispatcharr
    modules.services.postgresql.main.databases.dispatcharr = {
      owner = "dispatcharr";
      ownerPasswordFile = config.sops.secrets."postgresql/dispatcharr_password".path;
      extensions = [ "uuid-ossp" ];
      permissionsPolicy = "owner-readwrite+readonly-select";
    };

    # Dispatcharr container service configuration
    # IPTV stream management
    # TODO: Re-enable dispatcharr once shared PostgreSQL instance is implemented
    # ISSUE: Container runs multiple services as different users (postgres UID 102, dispatch UID 569)
    #        which creates volume permission conflicts. The embedded PostgreSQL can't write to
    #        /data/db because the volume is owned by UID 569. Need to either:
    #        1. Use a shared PostgreSQL service instead of embedded one, OR
    #        2. Implement proper multi-user volume permission strategy
    # See: https://github.com/Dispatcharr/Dispatcharr for container architecture
    modules.services.dispatcharr = {
      enable = false;  # DISABLED - needs shared PostgreSQL implementation

      # -- Container Image Configuration --
      # Pin to specific version for stability
      # Find releases at: https://github.com/Dispatcharr/Dispatcharr/releases
      image = "ghcr.io/dispatcharr/dispatcharr:latest";  # TODO: Pin to specific version when stable

      # dataDir defaults to /var/lib/dispatcharr (dataset mountpoint)
      healthcheck.enable = true;  # Enable container health monitoring
      backup = {
        enable = true;
        repository = "nas-primary";  # Primary NFS backup repository
      };
      notifications.enable = true;  # Enable failure notifications
      preseed = {
        enable = true;  # Enable self-healing restore
        repositoryUrl = "/mnt/nas-backup";
        passwordFile = config.sops.secrets."restic/password".path;
        # environmentFile not needed for local filesystem repository
      };
    };
  };
}
