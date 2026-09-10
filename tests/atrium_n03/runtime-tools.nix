{ pkgs }:
{
  inherit (pkgs) caddy socat nftables iproute2;
  node = pkgs.nodejs_22;
  privilege = pkgs.util-linux;
  certifi = pkgs.python312Packages.certifi;
}
