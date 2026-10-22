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

  # Dedicated, unprivileged SSH user for Ryan's cloud assistant box.
  # It connects only over the WireGuard tunnel (peer 10.8.0.4, see the
  # network-config repo), so the key is pinned to that source address with
  # `from=`. Agent/X11/port forwarding are disabled so the session cannot be
  # used to pivot into the rest of the network.
  #
  # Intentionally NOT in wheel (no doas/sudo) or any service/admin group, and
  # given its own primary group rather than `users`. No password is set
  # (mutableUsers = false + locked password), so key auth is the only way in.
  # Access is limited to what an ordinary user can read on Forge. If journal
  # access is ever wanted, add "systemd-journal" to extraGroups.
  users.users.grokbot = {
    isNormalUser = true;
    description = "Cloud assistant box (SSH via WireGuard 10.8.0.4)";
    group = "grokbot";
    extraGroups = [ ];
    shell = pkgs.bash;
    hashedPassword = "!"; # locked: no password login
    openssh.authorizedKeys.keys = [
      ''from="10.8.0.4",no-agent-forwarding,no-X11-forwarding,no-port-forwarding ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIC+/aS6swwQyZhz6lpazJj2BFhequRtAyJIHvjTvJN/w grokbot-box''
    ];
  };

  users.groups.grokbot = { };

  # Enable shared service groups (media, etc.) from centralized module
  # This replaces the inline users.groups.media definition
  modules.users.sharedGroups.enable = true;

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
