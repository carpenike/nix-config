{ pkgs, ... }:

{
  # UPS system control (graceful shutdown on low battery)
  # Using Network UPS Tools (NUT) to monitor the remote APC device at 10.9.18.245
  #
  # NixOS 25.05 uses power.ups module (not services.nut)
  # This configuration uses NUT in netclient mode to monitor a remote UPS server.
  # The system will automatically shutdown gracefully when the UPS battery is critically low.
  #
  # TODO: Add Prometheus metrics export via node_exporter textfile collector

  power.ups = {
    enable = true;
    mode = "netclient";

    # Monitor the remote UPS
    upsmon.monitor.apc = {
      system = "apc@10.9.18.245";
      powerValue = 1;
      user = "monuser";
      # Use empty password since APC doesn't have password auth configured
      # If you set a password in APC later, use sops-nix:
      # passwordFile = config.sops.secrets.ups-password.path;
      passwordFile = toString (pkgs.writeText "ups-password" "");
      type = "slave";  # This system is secondary/slave to the UPS
    };
  };

  # Install NUT client utilities for manual UPS querying
  environment.systemPackages = [ pkgs.nut ];
}
