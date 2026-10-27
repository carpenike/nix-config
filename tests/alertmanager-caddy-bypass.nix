# Eval-time checks for the Alertmanager Caddy bypass on Forge.
# The rendered Caddyfile must open POST /api/v2/alerts only, and only from
# the four cluster node addresses. The Pocket ID authorize route stays in
# place for every other request.
{ lib, caddyfile }:
let
  # Site blocks are introduced by an FQDN at column 0 ("am.holthome.net {").
  # Requiring a dot avoids the column-0 `tls {` block the ACME snippet emits
  # inside each site. Indented matcher and route blocks are not split points.
  chunks = builtins.split "\n([[:alnum:]][[:alnum:].-]*\\.[[:alnum:].-]+) \\{" caddyfile;

  findBody = name: rest:
    if rest == [ ] then null
    else if builtins.isList (builtins.head rest) && builtins.head rest == [ name ] then
      let tail = builtins.tail rest; in
      if tail == [ ] then null else builtins.head tail
    else findBody name (builtins.tail rest);

  remainderAfter = text: needle:
    let parts = lib.splitString needle text; in
    if builtins.length parts < 2 then null
    else builtins.concatStringsSep needle (builtins.tail parts);

  countOf = text: needle:
    builtins.length (lib.splitString needle text) - 1;

  site = findBody "am.holthome.net" chunks;
  prometheus = findBody "prom.holthome.net" chunks;

  matcherStart = "@caddy_security_bypass_am_holthome_net {";
  afterMatcher = if site == null then null else remainderAfter site matcherStart;

  # Lines of the bypass matcher, stopping at its closing brace.
  matcherLines =
    if afterMatcher == null then [ ]
    else
      let
        lines = lib.splitString "\n" afterMatcher;
        take = acc: rest:
          if rest == [ ] then acc
          else
            let line = builtins.head rest; in
            if builtins.match "[[:space:]]*}[[:space:]]*" line != null then acc
            else take (acc ++ [ line ]) (builtins.tail rest);
      in
      take [ ] lines;

  matcherInterior = lib.concatStringsSep "\n" matcherLines;

  alertsExpression = ''path_regexp "^/api/v2/alerts$"'';
  sledPeers = "remote_ip 10.20.10.20/32 10.20.10.21/32 10.20.10.22/32 10.20.10.23/32";

  beforeAuthorize =
    if site == null then ""
    else builtins.head (lib.splitString "authorize with admins" site);
  afterAuthorize =
    if site == null then null
    else remainderAfter site "authorize with admins";

  checks = {
    site_found = site != null;
    prometheus_site_found = prometheus != null;
    exact_alerts_path = lib.hasInfix alertsExpression matcherInterior;
    post_only = lib.hasInfix "method POST" matcherInterior;
    sled_peers = lib.hasInfix sledPeers matcherInterior;
    # A path matcher here would OR extra prefixes into the same bypass.
    bypass_has_no_path_matcher = !lib.hasInfix "path " matcherInterior;
    bypass_uses_remote_ip_not_client_ip = lib.hasInfix "remote_ip " matcherInterior && !lib.hasInfix "client_ip" matcherInterior;
    bypass_does_not_name_get = !lib.hasInfix "GET" matcherInterior;
    one_remote_ip_in_alertmanager_site = site != null && countOf site "remote_ip" == 1;
    sled_cidr_once_in_caddyfile = countOf caddyfile "10.20.10.20/32" == 1;
    authorize_remains = site != null && lib.hasInfix "authorize with admins" site;
    bypass_is_before_authorize = lib.hasInfix matcherStart beforeAuthorize && lib.hasInfix "remote_ip" beforeAuthorize;
    no_remote_ip_after_authorize = afterAuthorize != null && !lib.hasInfix "remote_ip" afterAuthorize;
    alertmanager_backend_stays_loopback = site != null && lib.hasInfix "reverse_proxy http://127.0.0.1:9093" site;
    no_static_api_key_on_alertmanager = site != null && !lib.hasInfix "static_api_key" site;
    # Prefix bypasses for the *arr apps must keep working, and must not inherit this peer list.
    media_prefix_bypass_unchanged = lib.hasInfix "path /api* /feed* /ping*" caddyfile;
    prometheus_ui_not_bypassed = prometheus != null
      && !lib.hasInfix "10.20.10." prometheus
      && !lib.hasInfix "@caddy_security_bypass_" prometheus;
  };

  # Stock Caddy can adapt this fragment (no caddy-security directives). The
  # matcher lines are the ones rendered for Forge, not a hand-written copy.
  adaptSnippet = ''
    {
      admin off
      auto_https off
    }
    http://127.0.0.1:9093 {
      ${matcherStart}
    ${matcherInterior}
      }

      route @caddy_security_bypass_am_holthome_net {
        reverse_proxy 127.0.0.1:9093
      }

      route {
        respond "gated" 401
      }
    }
  '';
in
{
  inherit checks adaptSnippet;
  sitePreview = if site == null then null else lib.substring 0 2500 site;
}
