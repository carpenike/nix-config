{ pkgs, ... }:

{
  # UPS system control (graceful shutdown on low battery)
  # Using Network UPS Tools (NUT) to monitor APC Smart-UPS 2200 RM XL at 10.9.18.245
  #
  # NixOS 25.05 uses power.ups module (not services.nut)
  # APC Network Management Cards use SNMP, not NUT server (upsd)
  # This uses standalone mode with snmp-ups driver to monitor via SNMP
  #
  # TODO: Add Prometheus metrics export via node_exporter textfile collector
  # TODO: Change SNMP community string from 'public' for better security

  power.ups = {
    enable = true;
    mode = "standalone";

    # Define the UPS - using snmp-ups driver for APC network management card
    ups.apc = {
      driver = "snmp-ups";
      port = "10.9.18.245";  # IP address of the APC network management card
      description = "APC Smart-UPS 2200 RM XL";

      # SNMP driver configuration for APC
      directives = [
        "mibs = apcc"           # Use APC MIB for Smart-UPS series
        "community = public"     # Default SNMP community string (TODO: verify/change)
      ];
    };

    # Monitor the local UPS (upsd runs locally in standalone mode)
    upsmon.monitor.apc = {
      system = "apc@localhost";
      powerValue = 1;
      user = "upsmon";
      passwordFile = toString (pkgs.writeText "upsmon-password" "changeme");
      type = "primary";  # This system initiates shutdown (formerly "master")
    };

    # Define the upsmon user for local upsd access
    users.upsmon = {
      passwordFile = toString (pkgs.writeText "upsmon-password" "changeme");
      upsmon = "primary";  # Primary monitoring role (formerly "master")
      # Allow this user to set variables and trigger forced shutdown
      actions = [ "set" "fsd" ];
      instcmds = [ "all" ];
    };
  };

  # Install NUT client utilities for manual UPS querying
  # Use: upsc apc@localhost to check UPS status
  environment.systemPackages = [ pkgs.nut ];
}
