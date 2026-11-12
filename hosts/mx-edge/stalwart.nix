# Stalwart v1.1.0, MTA only, as a container: nixpkgs packages 0.15.x, whose
# file-based configuration v1 replaced. The image is the one the cluster
# runs (k8s-gitops kubernetes/apps/mail/stalwart), so both ends stay on one
# version. Settings (domains, recipients, the relay route to the cluster,
# ACME, spam filter) live in its RocksDB store under /var/lib/stalwart and
# are managed from the WebUI on :8080 over the tailnet; export them with
# `stalwart-cli snapshot`.
{ config, ... }:
let
  dataDir = "/var/lib/stalwart";
  # The image's user (uid and gid 2000).
  uid = 2000;
in
{
  modules.services.podman.enable = true;

  # Only the DataStore: everything else is in the store itself. A small
  # block cache, because the host has 1 GiB.
  environment.etc."stalwart/config.json".text = builtins.toJSON {
    "@type" = "RocksDb";
    path = "${dataDir}/data";
    cacheSize = 134217728;
  };

  systemd.tmpfiles.rules = [
    "d ${dataDir} 0750 ${toString uid} ${toString uid} - -"
    "d ${dataDir}/data 0750 ${toString uid} ${toString uid} - -"
  ];

  virtualisation.oci-containers.containers.stalwart = {
    # renovate: depName=docker.io/stalwartlabs/stalwart datasource=docker
    image = "docker.io/stalwartlabs/stalwart:v1.1.0@sha256:f772aa6ef8cd8018969fa491640f1436b0270eb14e2c219b5f37f1a77020837e";
    # Host networking: port 25 on the public address, 8080 on the tailnet
    # (the firewall decides which), and the relay to the cluster leaves
    # through tailscale0's subnet route.
    extraOptions = [
      "--network=host"
      "--memory=640m"
    ];
    environment = {
      # SMTP greeting and EHLO name; must match the address's PTR.
      STALWART_HOSTNAME = "mx.holthome.net";
    };
    # STALWART_RECOVERY_ADMIN, STALWART_CLOUDFLARE_TOKEN
    environmentFiles = [ config.sops.templates."stalwart.env".path ];
    volumes = [
      "${dataDir}:${dataDir}"
      "/etc/stalwart/config.json:/etc/stalwart/config.json:ro"
    ];
  };

  systemd.services.podman-stalwart.restartTriggers = [
    config.environment.etc."stalwart/config.json".source
  ];

  # The WebUI and management API, for the tailnet only.
  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 8080 ];
}
