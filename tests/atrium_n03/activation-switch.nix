{ pkgs, configuration, hostPkgs ? pkgs }:
let
  inherit (pkgs) lib;
  serving = configuration.systemd.services.atrium-resolver;
  postgres = configuration.systemd.services.postgresql;
  provision = configuration.systemd.services.postgresql-provision-databases;
  readiness = configuration.systemd.services.postgresql-readiness-wait;
  server = version: pkgs.writeText "resolver-version-${version}.py" ''
    from http.server import BaseHTTPRequestHandler, HTTPServer
    from pathlib import Path

    marker = Path("/var/lib/activation-proof/retained")
    if not marker.exists():
        marker.write_text("synthetic retained state\n")

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"${version}")
        def log_message(self, *args):
            pass

    HTTPServer(("127.0.0.1", 18765), Handler).serve_forever()
  '';
  machine = fixed: { config, ... }: {
    options.activationProof.version = lib.mkOption {
      type = lib.types.enum [ "old" "new" "failed" ];
      default = "old";
    };
    options.activationProof.postReload = lib.mkOption {
      type = lib.types.bool;
      default = fixed;
    };
    config =
      let
        version = config.activationProof.version;
        isOld = version == "old";
        postReload = config.activationProof.postReload;
        sql = pkgs.writeText "provision-${version}.sql" ''
          \set ON_ERROR_STOP on
          ${lib.optionalString (version == "failed") "SELECT missing_activation_function();"}
          CREATE TABLE IF NOT EXISTS activation_state (
            singleton boolean PRIMARY KEY DEFAULT true,
            marker text NOT NULL,
            runs integer NOT NULL DEFAULT 0
          );
          INSERT INTO activation_state(singleton, marker) VALUES (true, 'retained')
          ON CONFLICT (singleton) DO NOTHING;
          ${lib.optionalString (!isOld) "ALTER TABLE activation_state ADD COLUMN IF NOT EXISTS cashflow_payload text;"}
          UPDATE activation_state SET runs = runs + 1;
        '';
      in
      {
        virtualisation = { memorySize = 768; cores = 2; vlans = [ ]; };
        networking.useDHCP = false;
        specialisation.updated.configuration.activationProof.version = "new";
        specialisation.failed.configuration.activationProof.version = "failed";
        specialisation.repaired.configuration.activationProof = {
          version = "new";
          postReload = true;
        };
        services.postgresql = {
          enable = true;
          package = pkgs.postgresql_17;
          settings.max_connections = if isOld then 20 else 24;
        };
        systemd.services = {
          postgresql.stopIfChanged = if postReload then postgres.stopIfChanged else true;
          atrium-resolver = {
            wantedBy = [ "multi-user.target" ];
            stopIfChanged = if postReload then serving.stopIfChanged else true;
            serviceConfig = {
              ExecStart = "${pkgs.python3}/bin/python ${server version}";
              StateDirectory = "activation-proof";
              Restart = "on-failure";
            };
          };
          postgresql-readiness-wait = {
            inherit (readiness) after requires;
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              User = "postgres";
              ExecStart = "${pkgs.postgresql_17}/bin/psql -X -qAt -v ON_ERROR_STOP=1 -d postgres -c 'SELECT NOT pg_is_in_recovery()'";
            };
          };
          postgresql-provision-databases = {
            wantedBy = [ "multi-user.target" ];
            inherit (provision) after requires;
            stopIfChanged = if postReload then provision.stopIfChanged else true;
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              User = "postgres";
              ExecStart = "${pkgs.postgresql_17}/bin/psql -X -q -v ON_ERROR_STOP=1 -d postgres -f ${sql}";
            };
          };
          activation-consumer = {
            after = [ "atrium-resolver.service" "postgresql-provision-databases.service" ];
            requires = [ "atrium-resolver.service" "postgresql-provision-databases.service" ];
            unitConfig.StartLimitIntervalSec = 0;
            serviceConfig.Type = "oneshot";
            script = "true";
          };
        };
        systemd.timers.activation-consumer = {
          wantedBy = [ "timers.target" ];
          timerConfig = { OnActiveSec = "100ms"; OnUnitInactiveSec = "100ms"; AccuracySec = "1ms"; };
        };
        system.activationScripts.activationProofWindow = {
          deps = [ "etc" ];
          text = lib.optionalString (!isOld) ''
            ${pkgs.coreutils}/bin/sleep 5
          '';
        };
        environment.systemPackages = [ pkgs.curl pkgs.postgresql_17 pkgs.util-linux ];
        system.stateVersion = "25.11";
      };
  };
in
assert !serving.stopIfChanged && serving.restartIfChanged;
assert !postgres.stopIfChanged && postgres.restartIfChanged;
assert !provision.stopIfChanged && provision.restartIfChanged;
hostPkgs.testers.runNixOSTest {
  name = "atrium-in-place-activation";
  globalTimeout = 300;
  node.pkgs = lib.mkForce pkgs;
  nodes = {
    unguarded = machine false;
    guarded = machine true;
  };
  testScript = ''
    import json

    start_all()
    groups = []
    for node in (unguarded, guarded):
        node.wait_for_unit("multi-user.target")
        node.wait_for_unit("atrium-resolver")
        node.wait_for_unit("postgresql-provision-databases")
        node.wait_for_unit("activation-consumer.timer")
        node.wait_until_succeeds("curl -fsS http://127.0.0.1:18765/ | grep -qx old")

    def sql(node, statement):
        import shlex
        return node.succeed("runuser -u postgres -- psql -X -qAt -v ON_ERROR_STOP=1 -d postgres -c " + shlex.quote(statement)).strip()

    def version(node):
        return node.succeed("curl -fsS http://127.0.0.1:18765/").strip()

    for node in (unguarded, guarded):
        node.succeed("readlink -f /run/current-system > /run/old-system")
        node.succeed("sha256sum /var/lib/activation-proof/retained > /run/retained.sha256")
        assert sql(node, "SHOW max_connections") == "20"
        assert sql(node, "SELECT marker FROM activation_state") == "retained"
    unguarded.succeed("$(cat /run/old-system)/specialisation/updated/bin/switch-to-configuration test", timeout=90)
    assert version(unguarded) == "old"
    assert "resolver-version-new.py" in unguarded.succeed("systemctl show atrium-resolver -p ExecStart --value")
    assert sql(unguarded, "SHOW max_connections") == "20"
    assert sql(unguarded, "SELECT count(*) FROM information_schema.columns WHERE table_name='activation_state' AND column_name='cashflow_payload'") == "0"
    groups.append("early-stop-late-start-reproduces-stale-process-and-provisioning")

    unguarded.succeed("$(cat /run/old-system)/specialisation/repaired/bin/switch-to-configuration test", timeout=90)
    assert version(unguarded) == "new"
    assert sql(unguarded, "SHOW max_connections") == "24"
    assert sql(unguarded, "SELECT count(*) FROM information_schema.columns WHERE table_name='activation_state' AND column_name='cashflow_payload'") == "1"
    assert sql(unguarded, "SELECT marker FROM activation_state") == "retained"
    unguarded.succeed("sha256sum --check /run/retained.sha256")
    groups.append("repair-switch-recovers-already-stale-process-and-schema-without-reset")

    guarded.succeed("$(cat /run/old-system)/specialisation/updated/bin/switch-to-configuration test", timeout=90)
    assert version(guarded) == "new"
    assert sql(guarded, "SHOW max_connections") == "24"
    assert sql(guarded, "SELECT count(*) FROM information_schema.columns WHERE table_name='activation_state' AND column_name='cashflow_payload'") == "1"
    assert sql(guarded, "SELECT marker FROM activation_state") == "retained"
    guarded.succeed("sha256sum --check /run/retained.sha256")
    groups.append("post-reload-restart-loads-new-process-config-and-schema")

    pid = guarded.succeed("systemctl show atrium-resolver -p MainPID --value").strip()
    runs = sql(guarded, "SELECT runs FROM activation_state")
    guarded.succeed("$(cat /run/old-system)/specialisation/updated/bin/switch-to-configuration test", timeout=90)
    assert guarded.succeed("systemctl show atrium-resolver -p MainPID --value").strip() == pid
    assert sql(guarded, "SELECT runs FROM activation_state") == runs
    guarded.succeed("sha256sum --check /run/retained.sha256")
    groups.append("unchanged-switch-does-not-restart-or-rerun-provisioning")

    guarded.fail("$(cat /run/old-system)/specialisation/failed/bin/switch-to-configuration test", timeout=90)
    guarded.succeed("systemctl is-failed postgresql-provision-databases")
    assert sql(guarded, "SELECT marker FROM activation_state") == "retained"
    guarded.succeed("$(cat /run/old-system)/specialisation/updated/bin/switch-to-configuration test", timeout=90)
    guarded.wait_for_unit("postgresql-provision-databases")
    assert version(guarded) == "new"
    assert sql(guarded, "SELECT marker FROM activation_state") == "retained"
    guarded.succeed("sha256sum --check /run/retained.sha256")
    groups.append("failed-provisioning-is-visible-and-recovery-preserves-state")
    print(json.dumps({
        "kind": "atrium.in-place-activation",
        "groups": groups,
        "actual_switch_to_configuration": True,
        "actual_postgresql": True,
        "scope": "Versioned fixture daemon and actual PostgreSQL; production lifecycle settings consumed unchanged, no native-auth claim.",
        "production_operations": False,
    }, sort_keys=True))
  '';
}
