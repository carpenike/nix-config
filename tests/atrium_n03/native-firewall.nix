{ pkgs, configuration, hostPkgs ? pkgs }:
let
  inherit (pkgs) lib;
  rules = configuration.system.build.atriumNativeFirewallRules;
  nativeLines = commands: lib.filter
    (line: lib.hasInfix "ATRIUM-NATIVE" line || lib.hasInfix "atrium-native-private.rules" line)
    (lib.splitString "\n" commands);
  start = nativeLines configuration.networking.firewall.extraCommands;
  stop = nativeLines configuration.networking.firewall.extraStopCommands;
  caddy = toString configuration.users.users.caddy.uid;
  resolver = toString configuration.users.users.atrium-resolver.uid;
  server = pkgs.writeText "atrium-native-firewall-http.py" ''
    from http.server import BaseHTTPRequestHandler, HTTPServer
    import sys

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"synthetic native boundary\n")

        def log_message(self, *args):
            pass

    HTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
  '';
in
assert lib.assertMsg (lib.length start == 3 && lib.length stop == 3)
  "Review the actual native firewall start/stop extraction after changing its command shape.";
hostPkgs.testers.runNixOSTest {
  name = "atrium-native-firewall";
  globalTimeout = 180;
  node.pkgs = lib.mkForce pkgs;
  nodes.machine = {
    virtualisation = { memorySize = 512; cores = 2; vlans = [ ]; };
    networking = {
      useDHCP = false;
      firewall = {
        enable = true;
        extraCommands = lib.concatStringsSep "\n" start;
        extraStopCommands = lib.concatStringsSep "\n" stop;
      };
    };
    systemd.services = lib.genAttrs [ "native-boundary" "unrelated-boundary" ]
      (name: {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = "${pkgs.python3}/bin/python ${server} ${if name == "native-boundary" then "9200" else "9201"}";
      });
    environment.systemPackages = [ pkgs.iptables pkgs.curl pkgs.util-linux ];
    system.stateVersion = "25.11";
  };
  testScript = ''
    import json

    machine.start()
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("native-boundary")
    machine.wait_for_unit("unrelated-boundary")
    machine.wait_for_unit("firewall")
    assert "nf_tables" in machine.succeed("iptables --version")
    groups = []

    def request(uid, port):
        return f"setpriv --reuid={uid} --regid=65534 --clear-groups curl --noproxy '*' --silent --show-error --max-time 2 http://127.0.0.1:{port}/"

    def boundary():
        for uid in (${caddy}, ${resolver}):
            assert "synthetic native boundary" in machine.succeed(request(uid, 9200))
        for uid in (0, 65534):
            machine.fail(request(uid, 9200))
            machine.succeed(request(uid, 9201))
        hooks = machine.succeed("iptables -S OUTPUT")
        assert sum("ATRIUM-NATIVE" in line for line in hooks.splitlines()) == 1
        entries = machine.succeed("iptables -S ATRIUM-NATIVE")
        assert "-p tcp" in next(line for line in entries.splitlines() if "--reject-with tcp-reset" in line)
        assert sum(line.startswith("-A ") for line in entries.splitlines()) == 3

    boundary()
    groups.append("actual-generated-rules-load-and-enforce-two-permits-and-two-denials")
    machine.succeed("systemctl stop firewall")
    machine.succeed("sed 's/-A ATRIUM-NATIVE -p tcp -j REJECT/-A ATRIUM-NATIVE -j REJECT/' ${rules} > /run/native-firewall-invalid.rules")
    code, output = machine.execute("iptables-restore --wait --noflush < /run/native-firewall-invalid.rules 2>&1")
    assert code != 0 and "Invalid argument" in output and "ATRIUM-NATIVE" in output
    groups.append("missing-explicit-tcp-reproduces-the-owner-kernel-refusal")

    machine.succeed("systemctl start firewall")
    machine.wait_for_unit("firewall")
    boundary()
    groups.append("failed-restore-recovers-through-real-firewall-service-start")
    machine.succeed("systemctl reload firewall")
    boundary()
    groups.append("firewall-reload-retains-boundary-without-duplicate-hooks")
    machine.succeed("systemctl restart firewall")
    machine.wait_for_unit("firewall")
    boundary()
    groups.append("firewall-restart-retains-boundary-and-unrelated-loopback")

    print(json.dumps({
        "kind": "atrium.native-firewall",
        "backend": "iptables-nft",
        "rules": "${rules}",
        "groups": groups,
        "actual_generated_commands": True,
        "production_operations": False,
    }, sort_keys=True))
  '';
}
