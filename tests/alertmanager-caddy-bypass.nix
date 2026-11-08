# Eval-time checks for the cluster's Caddy bypasses on Forge.
# Alertmanager: POST /api/v2/alerts only, from the four cluster node
# addresses. Prometheus and Loki: GET on their read APIs only, from the same
# addresses (the cluster Grafana's datasources). Pocket ID (Alertmanager,
# Prometheus) and basic auth (Loki) stay in place for every other request.
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
  loki = findBody "loki.holthome.net" chunks;

  # Lines of a named block opened by `start`, up to its first closing brace.
  blockLines = text: start:
    let after = if text == null then null else remainderAfter text start; in
    if after == null then [ ]
    else
      let
        take = acc: rest:
          if rest == [ ] then acc
          else
            let line = builtins.head rest; in
            if builtins.match "[[:space:]]*}[[:space:]]*" line != null then acc
            else take (acc ++ [ line ]) (builtins.tail rest);
      in
      take [ ] (lib.splitString "\n" after);

  promMatcher = lib.concatStringsSep "\n"
    (blockLines prometheus "@caddy_security_bypass_prom_holthome_net {");
  promRead = ''path_regexp "^/api/v1/(query|query_range|query_exemplars|series|labels|label/[^/]+/values|metadata|status/buildinfo|format_query|rules|alerts)$"'';

  # The `not {` block inside @basic_auth_required.
  lokiNot = lib.concatStringsSep "\n" (blockLines loki "not {");
  lokiRead = ''path_regexp "^/loki/api/v1/(query|query_range|labels|label/[^/]+/values|series|index/(stats|volume|volume_range)|patterns|detected_fields|detected_field/[^/]+/values|detected_labels|status/buildinfo|format_query)$"'';

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
    # Alertmanager, Prometheus and Loki; nowhere else.
    sled_cidr_three_times_in_caddyfile = countOf caddyfile "10.20.10.20/32" == 3;
    authorize_remains = site != null && lib.hasInfix "authorize with admins" site;
    bypass_is_before_authorize = lib.hasInfix matcherStart beforeAuthorize && lib.hasInfix "remote_ip" beforeAuthorize;
    no_remote_ip_after_authorize = afterAuthorize != null && !lib.hasInfix "remote_ip" afterAuthorize;
    alertmanager_backend_stays_loopback = site != null && lib.hasInfix "reverse_proxy http://127.0.0.1:9093" site;
    no_static_api_key_on_alertmanager = site != null && !lib.hasInfix "static_api_key" site;
    # Prefix bypasses for the *arr apps must keep working, and must not inherit this peer list.
    media_prefix_bypass_unchanged = lib.hasInfix "path /api* /feed* /ping*" caddyfile;
    # Prometheus: GET on the read API from the sleds; Pocket ID otherwise.
    prometheus_read_path = lib.hasInfix promRead promMatcher;
    prometheus_get_only = lib.hasInfix "method GET" promMatcher && !lib.hasInfix "POST" promMatcher;
    prometheus_sled_peers = lib.hasInfix sledPeers promMatcher;
    prometheus_no_path_prefix = !lib.hasInfix "path " promMatcher;
    prometheus_one_remote_ip = prometheus != null && countOf prometheus "remote_ip" == 1;
    prometheus_authorize_remains = prometheus != null && lib.hasInfix "authorize with admins" prometheus;
    prometheus_static_key_kept = prometheus != null && lib.hasInfix "PROMETHEUS_BACKUP_API_KEY" prometheus;
    # Loki: basic auth for everything except GET on the read API from the sleds.
    loki_site_found = loki != null;
    loki_auth_is_conditional = loki != null
      && lib.hasInfix "basic_auth @basic_auth_required {" loki
      && !lib.hasInfix "basic_auth {" loki;
    loki_read_path = lib.hasInfix lokiRead lokiNot;
    loki_get_only = lib.hasInfix "method GET" lokiNot && !lib.hasInfix "POST" lokiNot;
    loki_sled_peers = lib.hasInfix sledPeers lokiNot;
    loki_push_not_opened = !lib.hasInfix "push" lokiNot && !lib.hasInfix "tail" lokiNot;
    loki_one_remote_ip = loki != null && countOf loki "remote_ip" == 1;
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
