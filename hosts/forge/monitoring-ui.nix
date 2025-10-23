# Monitoring UI Exposure Configuration
# Provides LAN-only access to Prometheus and Alertmanager web interfaces
# with basic authentication from SOPS secrets.

{ config, pkgs, ... }:

{
  # Expose Prometheus UI on subdomain with LAN-only access
  modules.services.caddy.virtualHosts."prometheus" = {
    enable = true;
    hostName = "prometheus.forge.holthome.net";
    proxyTo = "127.0.0.1:9090";
    httpsBackend = false;

    # Basic authentication using SOPS secret
    auth = {
      user = "admin";
      passwordHashEnvVar = "MONITORING_BASIC_AUTH_PASSWORD";
    };

    # Security headers and additional configuration
    extraConfig = ''
      # Security headers
      header_up Host {upstream_hostport}
      header_up X-Real-IP {remote_host}
    '';
  };

  # Expose Alertmanager UI on subdomain with LAN-only access
  modules.services.caddy.virtualHosts."alertmanager" = {
    enable = true;
    hostName = "alertmanager.forge.holthome.net";
    proxyTo = "127.0.0.1:9093";
    httpsBackend = false;

    # Basic authentication using SOPS secret
    auth = {
      user = "admin";
      passwordHashEnvVar = "MONITORING_BASIC_AUTH_PASSWORD";
    };

    # Security headers and additional configuration
    extraConfig = ''
      # Security headers
      header_up Host {upstream_hostport}
      header_up X-Real-IP {remote_host}
    '';
  };

  # Load the monitoring basic auth password from SOPS
  sops.secrets."monitoring/basic-auth-password" = {
    sopsFile = ./secrets.sops.yaml;
    restartUnits = [ "caddy.service" "caddy-monitoring-env.service" ];
  };

  # Create environment file that Caddy can read
  # This service runs before Caddy and writes the password hash to an env file
  systemd.services.caddy-monitoring-env = {
    description = "Prepare Caddy monitoring authentication environment";
    unitConfig.PartOf = [ "caddy.service" ];
    before = [ "caddy.service" ];
    after = [ "sops-nix.service" ];
    wantedBy = [ "caddy.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = [ pkgs.coreutils ];
    script = ''
      mkdir -p /run/caddy
      echo "MONITORING_BASIC_AUTH_PASSWORD=$(cat ${config.sops.secrets."monitoring/basic-auth-password".path})" > /run/caddy/monitoring-auth.env
      chmod 600 /run/caddy/monitoring-auth.env
      chown ${config.services.caddy.user}:${config.services.caddy.group} /run/caddy/monitoring-auth.env
    '';
  };

  # Environment file is loaded in main configuration to avoid conflicts
}
