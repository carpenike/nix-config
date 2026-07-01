# Caddy reverse-proxy host wiring for nixpi.
#
# The Caddy module defaults every vhost to Cloudflare DNS-01 ACME, so Caddy needs
# a CLOUDFLARE_API_TOKEN in its environment to mint certificates (e.g. for
# iq.holtel.io, whose vhost is defined in ./coachiq.nix). The token lives
# encrypted in secrets.sops.yaml as an env-file-formatted secret
# (`CLOUDFLARE_API_TOKEN=...`) and is mounted here as Caddy's systemd
# EnvironmentFile.
#
# NOTE: this token MUST have Zone:DNS:Edit on the holtel.io zone. The separate
# cloudflare_api_token used by ./cloudflared.nix (tunnel DNS registration) may be
# a different token — keep their scopes in mind if consolidating.
{ config, ... }:
{
  config = {
    sops.secrets.caddy_cloudflare_env = {
      mode = "0400";
      owner = config.services.caddy.user;
      group = config.services.caddy.group;
      restartUnits = [ "caddy.service" ];
    };

    # Load the CLOUDFLARE_API_TOKEN into Caddy's process environment for DNS-01.
    systemd.services.caddy.serviceConfig.EnvironmentFile = [
      config.sops.secrets.caddy_cloudflare_env.path
    ];
  };
}
