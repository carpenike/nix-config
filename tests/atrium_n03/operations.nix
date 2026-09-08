{ fixture, lib }:
let
  f = fixture;
  defaults = import ../../lib/host-defaults.nix {
    inherit lib;
    config = { };
    hostConfig = { hostname = "atrium-n03-fixture"; };
  };
  units = {
    atrium-resolver = "AtriumResolverFixture";
    atrium-device-registration = "AtriumRegistrationFixture";
    homelab-mcp = "AtriumNativeFixture";
    whiskey-whiskey-whiskey = "AtriumWhiskeyFixture";
    caddy = "AtriumEntryFixture";
  };
in
{
  schema_version = 1;
  isolated = true;
  external_notifications_enabled = false;
  backup_jobs_enabled = false;
  alert_rules = lib.mapAttrs
    (unit: label: defaults.mkSystemdServiceDownAlert unit label "isolated foundation")
    units;
  health = {
    vantage_point = "external isolated client namespace";
    tls_ca_reference = "front-ca";
    endpoints = [
      { url = "${f.endpoints.resolver}/healthz"; expected_status = 200; }
      { url = "${f.endpoints.native}/healthz"; expected_status = 200; }
      { url = "${f.endpoints.whiskey}/api/status"; permitted_statuses = [ 200 401 403 ]; }
    ];
    authentication_and_freshness = "Separate actual permit/deny and signed-feed cases; liveness is not admission.";
  };
  backup = {
    execution = "owner-invoked coherent private snapshot; no scheduled or remote job";
    state_sets = [
      { paths = [ f.state.resolver ]; coherence = "SQLite/WAL, signing ring, identities, references and denies"; }
      { paths = [ f.state.native ]; coherence = "Native key, OAuth history/adoption markers and denial store"; }
      { paths = [ f.state.whiskey ]; coherence = "Native users/state and companion denial store"; }
    ];
    tags = defaults.backupTags.infrastructure ++ defaults.backupTags.database;
    exclude_runtime_credentials = true;
  };
  recovery = {
    independent_operator_path = true;
    executed_ssh_or_host_rebuild = false;
    commands_are_references_only = [
      "systemctl status atrium-resolver.service homelab-mcp.service whiskey-whiskey-whiskey.service"
      "journalctl -u atrium-resolver -u homelab-mcp -u whiskey-whiskey-whiskey"
    ];
    prohibit = [ "delete-adoption-marker" "restore-older-deny-generation" "lower-clock-high-water" "share-signing-uid" "unrestricted-fallback" ];
  };
}
