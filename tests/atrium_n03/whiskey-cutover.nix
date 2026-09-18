{ pkgs, whiskeyPackage, egressOrdering, hostPkgs ? pkgs }:
let
  inherit (pkgs) lib;
  root = "/run/atrium-whiskey-cutover";
  storeModule = "${whiskeyPackage}/share/whiskey-whiskey-whiskey/dist/server/lib/atrium-deny-store.js";
  settings = {
    schema_version = 1;
    issuer = "https://resolver.whiskey.invalid";
    jwks_uri = "https://resolver.whiskey.invalid/.well-known/jwks.json";
    native_issuer = "https://identity.whiskey.invalid";
    authority = "fixture";
    domain = "personal:fixture";
    instance_id = "fixture-whiskey";
    target = "https://whiskey.invalid/cc/mcp";
    isolated_harness = true;
    deny = {
      feed_uri = "https://resolver.whiskey.invalid/v1/deny-feed";
      state_directory = "";
    };
  };
  network = {
    hosts = [ "gateway.whiskey.invalid" ];
    dns_addresses = [ "192.0.2.53" ];
    uid = 1067;
  };
  networkFile = pkgs.writeText "whiskey-network-fixture.json" (builtins.toJSON network);
  networkCommand = "${pkgs.python312}/bin/python -I -B ${../../hosts/forge/atrium/whiskey-network.py}"
    + " --config ${networkFile}"
    + " --iptables-restore ${pkgs.iptables}/bin/iptables-restore"
    + " --iptables ${pkgs.iptables}/bin/iptables"
    + " --ip6tables ${pkgs.iptables}/bin/ip6tables";
  fixture = pkgs.writeText "whiskey-cutover-fixture.json" (builtins.toJSON {
    inherit root;
    helper = ../../hosts/forge/atrium/whiskey-cutover.py;
    store_module = storeModule;
    configuration = {
      schema_version = 1;
      installation = "whiskey-cutover-fixture";
      inherit settings;
      policy_directory = "";
      legacy_deny_directory = "";
      image_credentials = { };
      model_approval = "";
      bootstrap_config = "";
      node = "${pkgs.nodejs_22}/bin/node";
      bootstrap = ../../hosts/forge/atrium/whiskey-bootstrap.mjs;
      network_helper = ../../hosts/forge/atrium/whiskey-network.py;
      identity = { uid = 1067; gid = 1066; user = "whiskey-fixture"; group = "whiskey-delivery-fixture"; };
      model = {
        schema_version = 1;
        installation = "whiskey-cutover-fixture";
        issuer = "https://gateway.whiskey.invalid";
        model = "cc.personal.fixture.sonnet";
        template_id = "cc.personal.fixture.whiskey-service";
        key_path = "${root}/never-created-model-key";
        key_owner_uid = 1063;
        acknowledgement_path = "${root}/never-created-acknowledgement";
        isolated_harness = true;
      };
      egress = network;
    };
  });
  http = pkgs.writeText "whiskey-http-fixture.py" ''
    from http.server import BaseHTTPRequestHandler, HTTPServer
    import sys
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"fixture_request 1\n")
        def log_message(self, *args):
            pass
    HTTPServer((sys.argv[1], int(sys.argv[2])), Handler).serve_forever()
  '';
  metrics = import ../../hosts/forge/atrium/whiskey-metrics.nix { };
  stateProgram = pkgs.writeText "whiskey-state-fixture.py" ''
    import hashlib, json, os, sqlite3
    from pathlib import Path
    root = Path("/var/lib/whiskey-application-fixture")
    connection = sqlite3.connect(root / "db.sqlite")
    connection.execute("CREATE TABLE IF NOT EXISTS retained (id INTEGER PRIMARY KEY, value TEXT NOT NULL)")
    if os.environ["FIXTURE_MODE"] == "legacy":
        connection.execute("INSERT INTO retained VALUES (1, 'synthetic-retained-oauth-session')")
        connection.commit()
    assert connection.execute("SELECT value FROM retained WHERE id=1").fetchone()[0] == "synthetic-retained-oauth-session"
    connection.close()
    if os.environ["FIXTURE_MODE"] == "adopted":
        assert os.geteuid() == 1067 and os.getegid() == 1066
        (root / "retained-state-verified").write_text("verified\n")
  '';
in
hostPkgs.testers.runNixOSTest {
  name = "atrium-owner-whiskey-cutover";
  globalTimeout = 600;
  node.pkgs = lib.mkForce pkgs;
  nodes.machine = { config, ... }: {
    virtualisation = { memorySize = 1024; cores = 2; vlans = [ ]; };
    networking = {
      hostName = "atrium-whiskey-cutover-fixture";
      useDHCP = false;
      hosts."198.51.100.10" = [ "gateway.whiskey.invalid" ];
      firewall.enable = true;
    };
    users.groups = {
      whiskey-fixture.gid = 1067;
      whiskey-delivery-fixture.gid = 1066;
      unrelated-fixture.gid = 1070;
    };
    users.users = {
      whiskey-fixture = { isSystemUser = true; uid = 1067; group = "whiskey-fixture"; };
      unrelated-fixture = { isSystemUser = true; uid = 1070; group = "unrelated-fixture"; };
    };
    environment.systemPackages = [ pkgs.curl pkgs.iptables pkgs.iproute2 pkgs.util-linux ];
    services.caddy = {
      enable = true;
      extraConfig = ''
        http://127.0.0.1:13417 {
          ${metrics}
        }
      '';
    };
    systemd.services = {
      whiskey-network-ready-fixture = {
        wantedBy = [ "network-online.target" ];
        before = [ "network-online.target" ];
        script = ''
          sleep 2
          ${pkgs.iproute2}/bin/ip address add 198.51.100.10/32 dev lo
          ${pkgs.iproute2}/bin/ip address add 198.51.100.11/32 dev lo
          touch /run/whiskey-network-ready
        '';
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
      };
      whiskey-egress-fixture = egressOrdering // {
        wantedBy = [ "multi-user.target" ];
        script = ''
          test -f /run/whiskey-network-ready
          exec ${networkCommand}
        '';
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          NoNewPrivileges = true;
          CapabilityBoundingSet = [ "CAP_NET_ADMIN" ];
        };
      };
      whiskey-backend-fixture = {
        wantedBy = [ "multi-user.target" ];
        requires = [ "whiskey-egress-fixture.service" ];
        after = [ "whiskey-egress-fixture.service" ];
        serviceConfig = {
          User = "whiskey-fixture";
          ExecStart = "${pkgs.python312}/bin/python ${http} 127.0.0.1 3417";
        };
      };
      whiskey-provider-fixture = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = "${pkgs.python312}/bin/python ${http} 0.0.0.0 443";
      };
      whiskey-legacy-state-fixture = {
        environment.FIXTURE_MODE = "legacy";
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          DynamicUser = true;
          User = "whiskey-old-fixture";
          StateDirectory = "whiskey-application-fixture";
          StateDirectoryMode = "0700";
          ExecStart = "${pkgs.python312}/bin/python ${stateProgram}";
        };
      };
      whiskey-adopted-state-fixture = {
        environment.FIXTURE_MODE = "adopted";
        serviceConfig = {
          Type = "oneshot";
          DynamicUser = true;
          User = "whiskey-fixture";
          Group = "whiskey-delivery-fixture";
          StateDirectory = "whiskey-application-fixture";
          StateDirectoryMode = "0700";
          ReadWritePaths = [ "${root}/ordinary/whiskey-admission" ];
          ExecStart = [
            "${pkgs.python312}/bin/python ${stateProgram}"
            "${pkgs.nodejs_22}/bin/node ${../../hosts/forge/atrium/whiskey-bootstrap.mjs} --config ${root}/ordinary/bootstrap.json --confirm-existing-installation whiskey-cutover-fixture"
          ];
        };
      };
    };
    system.stateVersion = "25.11";
  };
  testScript = ''
    import json

    machine.start()
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("whiskey-egress-fixture")
    machine.wait_for_unit("whiskey-backend-fixture")
    result = json.loads(machine.succeed(
        "${pkgs.python312}/bin/python -I -B ${./whiskey-cutover-fixture.py} ${fixture}",
        timeout=300,
    ))
    assert result["groups_passed"] == 9
    assert result["real_installed_deny_store"] and not result["production_operations"]
    machine.succeed("systemctl start whiskey-legacy-state-fixture")
    machine.succeed("test -L /var/lib/whiskey-application-fixture")
    machine.succeed("systemctl stop whiskey-legacy-state-fixture")
    machine.succeed("systemctl start whiskey-adopted-state-fixture")
    machine.succeed("test -L /var/lib/whiskey-application-fixture")
    machine.succeed("test -s /var/lib/whiskey-application-fixture/retained-state-verified")
    machine.wait_for_open_port(3417)
    machine.wait_for_open_port(13417)
    machine.succeed("${networkCommand}")
    client = "setpriv --reuid=1067 --regid=1066 --clear-groups curl --noproxy '*' --silent --show-error --max-time 3 "
    machine.succeed(client + "http://198.51.100.10:443")
    machine.fail(client + "http://198.51.100.11:443")
    machine.succeed("setpriv --reuid=1070 --regid=1070 --clear-groups curl --noproxy '*' --silent --fail http://198.51.100.11:443")
    machine.succeed("iptables -I OUTPUT -o lo -d 127.0.0.1 -p tcp --dport 3417 -m owner ! --uid-owner caddy -j REJECT --reject-with tcp-reset")
    machine.fail("curl --silent --fail --max-time 3 http://127.0.0.1:3417/metrics")
    machine.succeed("curl --silent --fail http://127.0.0.1:13417/metrics")
    machine.fail("curl --noproxy '*' --silent --fail --max-time 3 -H 'Host: 127.0.0.1:13417' http://198.51.100.10:13417/metrics")
    for path in ["/", "/cc/mcp", "/api/mcp", "/metrics/extra"]:
        assert machine.succeed("curl --silent -o /dev/null -w '%{http_code}' http://127.0.0.1:13417" + path).strip() == "404"
    assert machine.succeed("curl --silent -X POST -o /dev/null -w '%{http_code}' http://127.0.0.1:13417/metrics").strip() == "404"
    machine.succeed("sed -i 's/198.51.100.10/198.51.100.11/' /etc/hosts")
    machine.succeed("${networkCommand}")
    machine.succeed(client + "http://198.51.100.11:443")
    machine.fail(client + "http://198.51.100.10:443")
    machine.succeed("cp /etc/hosts /run/whiskey-fixture-hosts")
    machine.succeed("sed -i '/gateway.whiskey.invalid/d' /etc/hosts")
    before = machine.succeed("iptables -S")
    machine.fail("${networkCommand}")
    assert machine.succeed("iptables -S") == before
    machine.succeed(client + "http://198.51.100.11:443")
    machine.succeed("cp /run/whiskey-fixture-hosts /etc/hosts")
    machine.succeed("${networkCommand}")
    result["host_groups"] = [
        "network-online-before-egress-and-consumer-start",
        "preallocated-uid-retains-idmapped-state-and-native-deny-access",
        "declared-egress-permits-and-foreign-address-refuses",
        "other-service-egress-unchanged",
        "backend-only-caddy-with-metrics-only-proxy",
        "dns-address-refresh-retires-old-address",
        "failed-resolution-retains-complete-boundary-and-recovers",
    ]
    print(json.dumps(result, sort_keys=True))
  '';
}
