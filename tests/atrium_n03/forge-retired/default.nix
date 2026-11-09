# The Forge services the Atrium checks still need, frozen as they were when
# they moved to the k8s cluster on 2026-11-08.
#
# ../adopted.nix and ../pre-adoption.nix extend the LIVE Forge configuration,
# and Atrium's adopted state wraps homelab-mcp (native profile, vhost headers,
# credential projection, the security-history dataset). Live Forge no longer
# runs homelab-mcp, so those fixtures add it back from here.
#
# schoolhouse and lading come along because homelab-mcp's unit reads the
# `homelab-mcp-schoolhouse-env` and `homelab-mcp-lading-env` sops templates,
# which hosts/forge/secrets.nix only declares while those services are enabled.
#
# Live Forge already imports inputs.homelab-mcp.nixosModules.default (options
# only, disabled) from hosts/forge/services/retired-to-cluster.nix, so it is not
# imported again here. The retention declarations in that file yield to these
# modules (they are gated on each service being disabled), so the fixture's
# datasets, backups and users come only from the files below.
{
  imports = [
    ./homelab-mcp.nix
    ./schoolhouse.nix
    ./lading.nix
  ];
}
