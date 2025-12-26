{ pkgs, lib, config, ... }:

let
  ifGroupsExist = groups: builtins.filter (group: builtins.hasAttr group config.users.groups) groups;
in
{
  # User configuration
  users.users.ryan = {
    uid = 1000;
    name = "ryan";
    home = "/home/ryan";
    group = "ryan";
    # Use bash as login shell for VS Code Remote SSH compatibility.
    # Fish is launched for interactive sessions via Home Manager's bash config.
    shell = pkgs.bash;
    openssh.authorizedKeys.keys = lib.strings.splitString "\n" (builtins.readFile ../../../home/ryan/config/ssh/ssh.pub);
    isNormalUser = true;
    extraGroups =
      [
        "wheel"
        "users"
        "podman" # Rootless podman container management
      ]
      ++ ifGroupsExist [
        "network"
        "esphome" # Edit ESPHome YAML configs via VS Code Remote SSH
        "hass" # Edit Home Assistant configs via VS Code Remote SSH
      ];
  };

  users.groups.ryan = {
    gid = 1000;
  };

  # Shared media group for *arr services and download clients
  # GID 65537 (993 was taken by alertmanager)
  users.groups.media = {
    gid = 65537;
  };

  # Add postgres user to restic-backup group for R2 secret access
  # and node-exporter group for metrics file write access
  # Required for pgBackRest to read AWS credentials and write Prometheus metrics
  users.users.postgres.extraGroups = [ "restic-backup" "node-exporter" ];

  # Add restic-backup user to media group for backup access
  # Media services (sonarr, radarr, bazarr, prowlarr, qbittorrent, recyclarr, etc.)
  # all run as group "media" (GID 65537) with 0750 directory permissions
  # Also add monitoring service groups (grafana, loki, promtail)
  users.users.restic-backup.extraGroups = [
    "media" # All *arr services, qbittorrent, recyclarr, etc.
    "grafana" # Grafana dashboards and database
    "loki" # Loki log storage
    "promtail" # Promtail positions file
  ];
}
