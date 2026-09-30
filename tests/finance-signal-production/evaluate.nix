{ inputs }:
let
  inherit (inputs.nixpkgs) lib;
  pkgs = inputs.nixpkgs.legacyPackages.x86_64-linux;
  package = inputs.homelab-mcp.packages.x86_64-linux.default;
  mkHost =
    { enabled ? true
    , hermes ? false
    , hermesModule ? true
    , stagingCapture ? true
    , stagingBoot ? false
    , stagingTimer ? false
    , before ? "2026-10-01T00:00:00-04:00"
    , version ? package.version
    , allowedUsers ? [ "homelab-mcp" ]
    }:
    (lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ../../hosts/forge/services/finance-signal.nix
        ../../hosts/forge/services/finance-signal-production.nix
        ({ lib, ... }: {
          options = {
            services.hermes-agent = lib.mkOption { type = lib.types.attrsOf lib.types.anything; };
            services.homelab-mcp = lib.mkOption { type = lib.types.attrsOf lib.types.anything; };
            modules.services.signal-api = lib.mkOption { type = lib.types.attrsOf lib.types.anything; };
            modules.services.postgresql.databases = lib.mkOption { type = lib.types.attrsOf lib.types.anything; default = { }; };
            modules.services.backup.restic.jobs = lib.mkOption { type = lib.types.attrsOf lib.types.anything; };
            modules.storage.datasets.services = lib.mkOption { type = lib.types.attrsOf lib.types.anything; };
            modules.monitoring.nodeExporter = lib.mkOption { type = lib.types.attrsOf lib.types.anything; };
            modules.alerting.rules = lib.mkOption { type = lib.types.attrsOf lib.types.anything; default = { }; };
            sops.secrets = lib.mkOption { type = lib.types.attrsOf lib.types.anything; default = { }; };
          };
          config = {
            system.stateVersion = "26.05";
            boot.isContainer = true;
            services.financeSignalProduction = { enable = enabled; reportsNotBefore = before; };
            services.financeSignalStaging = { reportReader.enable = true; capture.enable = stagingCapture; };
            services.hermes-agent.enable = hermesModule;
            services.homelab-mcp = {
              enable = true;
              package = package // { inherit version; };
              environmentFile = "/run/secrets/homelab-mcp/env";
            };
            modules.services = {
              signal-api = {
                enable = true;
                port = 18484;
                localAccess = { enable = true; subnet = "10.90.0.0/24"; inherit allowedUsers; };
              };
              backup.restic.jobs = { homelab-mcp.enable = true; homelab-mcp-offsite.enable = true; };
            };
            modules.storage.datasets.services.homelab-mcp.mountpoint = "/var/lib/homelab-mcp";
            modules.monitoring.nodeExporter = {
              enable = true;
              textfileCollector = { enable = true; directory = "/var/lib/node_exporter/textfile_collector"; };
            };
            services.prometheus.exporters.node.enabledCollectors = [ "systemd" ];
            users.users.homelab-mcp = { isSystemUser = true; group = "homelab-mcp"; };
            users.groups.homelab-mcp = { };
            systemd.services.homelab-mcp = {
              environment.HOMELAB_MCP_FINANCES_CONTEXT_DB_PATH = "/var/lib/homelab-mcp/finances-context.db";
              serviceConfig = {
                User = "homelab-mcp";
                Group = "homelab-mcp";
                ExecStart = "${pkgs.coreutils}/bin/true";
                EnvironmentFile = [ "/run/secrets/homelab-mcp/env" ];
              };
            };
            systemd.services.hermes-agent = {
              enable = hermes;
              serviceConfig.ExecStart = "${pkgs.coreutils}/bin/true";
            };
          };
        })
      ] ++ lib.optional stagingBoot {
        systemd.services.finance-signal-capture-staging.wantedBy = [ "multi-user.target" ];
      } ++ lib.optional stagingTimer {
        systemd.timers.staging-test = {
          wantedBy = [ "timers.target" ];
          timerConfig = { OnBootSec = "1m"; Unit = "finance-signal-capture-staging.service"; };
        };
      };
    }).config;
  on = mkHost { };
  off = mkHost { enabled = false; before = null; hermes = true; };
  captureOff = mkHost { stagingCapture = false; };
  bothOff = mkHost { enabled = false; stagingCapture = false; };
  passes = c: lib.all
    (a:
      a.assertion || !(lib.hasPrefix "finance-signal production" a.message))
    c.assertions;
  capture = on.systemd.services.finance-signal-capture;
  report = on.systemd.services."finance-signal-report@";
  monitor = on.systemd.services.finance-signal-metrics;
  dbDir = "/var/lib/homelab-mcp";
  transport = "/run/secrets/homelab-mcp/finance-signal-env";
  checks = {
    default-is-off =
      !(off.systemd.services ? finance-signal-capture)
      && !(off.systemd.services ? "finance-signal-report@")
      && !(off.systemd.services ? finance-signal-metrics)
      && off.modules.alerting.rules == { }
      && passes off;
    enabled-contract-passes = passes on;
    active-hermes-fails = !(passes (mkHost { hermes = true; }))
      && !(passes (mkHost { hermes = true; hermesModule = false; }));
    upstream-hermes-remains-declared =
      on.services.hermes-agent.enable && !on.systemd.services.hermes-agent.enable && passes on;
    production-retains-shared-secret-with-staging-capture-off =
      passes captureOff
      && captureOff.services.financeSignalStaging.reportReader.enable
      && !(captureOff.systemd.services ? finance-signal-capture-staging)
      && captureOff.sops.secrets == on.sops.secrets
      && captureOff.sops.secrets."homelab-mcp/finance-signal-env".owner == "root"
      && captureOff.sops.secrets."homelab-mcp/finance-signal-env".group == "root"
      && captureOff.sops.secrets."homelab-mcp/finance-signal-env".mode == "0400"
      && bothOff.sops.secrets == { }
      && lib.all (name: captureOff.systemd.services.${name}.serviceConfig.EnvironmentFile == [ transport ])
        [ "finance-signal-capture" "finance-signal-report@" "finance-signal-metrics" ];
    staging-autostart-fails = !(passes (mkHost { stagingBoot = true; }))
      && !(passes (mkHost { stagingTimer = true; }));
    cutover-is-required-and-offset-aware =
      !(passes (mkHost { before = null; }))
      && !(passes (mkHost { before = "2026-10-01T00:00:00"; }));
    old-package-and-wrong-uid-fail =
      !(passes (mkHost { version = "0.33.1"; }))
      && !(passes (mkHost { allowedUsers = [ "hermes" ]; }));
    no-new-secrets-roles-or-repair =
      on.sops.secrets == off.sops.secrets
      && on.modules.services.postgresql.databases == off.modules.services.postgresql.databases
      && !(capture.serviceConfig ? StateDirectory)
      && !(monitor.serviceConfig ? StateDirectory)
      && builtins.attrNames on.system.activationScripts == builtins.attrNames off.system.activationScripts;
    capture-is-one-boot-owner =
      capture.wantedBy == [ "multi-user.target" ]
      && builtins.elem "finance-signal-capture-staging.service" capture.conflicts
      && builtins.elem "hermes-agent.service" capture.conflicts
      && capture.unitConfig.StartLimitIntervalSec == 600
      && capture.unitConfig.StartLimitBurst == 3
      && capture.serviceConfig.Restart == "on-failure"
      && capture.serviceConfig.RestartSec == "30s"
      && capture.serviceConfig.TimeoutStopSec == "60s";
    capture-canonical-db-journals-and-dnat =
      capture.serviceConfig.ReadWritePaths == [ dbDir ]
      && capture.serviceConfig.IPAddressDeny == "any"
      && capture.serviceConfig.IPAddressAllow == [ "127.0.0.1/32" "::1/128" "10.90.0.0/24" ]
      && capture.unitConfig.AssertPathIsMountPoint == [ dbDir ]
      && lib.hasSuffix " capture ${on.services.homelab-mcp.package}/bin/homelab-finances-signal 18484"
        capture.serviceConfig.ExecStart;
    consumers-have-only-transport-env =
      lib.all
        (unit:
          unit.serviceConfig.EnvironmentFile == [ transport ]
          && unit.serviceConfig.User == "homelab-mcp"
          && unit.serviceConfig.Group == "homelab-mcp"
          && unit.serviceConfig.UMask == "0077"
          && builtins.elem "-/run/secrets" unit.serviceConfig.InaccessiblePaths
          && builtins.elem "-${dbDir}/state.db" unit.serviceConfig.InaccessiblePaths
          && builtins.elem "-${dbDir}/signing-key.pem" unit.serviceConfig.InaccessiblePaths)
        [ capture report monitor ];
    capture-and-monitor-have-no-reader-or-bank-paths =
      lib.all
        (unit: lib.all (path: builtins.elem path unit.serviceConfig.InaccessiblePaths)
          [ "-/run/finance-report-reader" "-/run/postgresql" "-${dbDir}/finances-ingest" "-${dbDir}/finance-reports" ])
        [ capture monitor ];
    reports-native-reader-and-bounded-no-retry =
      builtins.elem "finance-report-reader-config.service" report.requires
      && report.serviceConfig.BindReadOnlyPaths == [
        "/run/finance-report-reader"
        "/run/postgresql"
        "${dbDir}/finances-ingest"
      ]
      && report.serviceConfig.StateDirectory == "homelab-mcp/finance-reports"
      && lib.hasSuffix (" due %i " + lib.escapeShellArg "2026-10-01T00:00:00-04:00") report.serviceConfig.ExecCondition
      && lib.hasInfix "homelab-finances-signal-report %i 18484" report.serviceConfig.ExecStart
      && report.serviceConfig.TimeoutStartSec == "270s"
      && report.serviceConfig.TimeoutStopSec == "45s"
      && report.serviceConfig.Restart == "no"
      && !(report.serviceConfig ? SuccessExitStatus);
    exact-nonpersistent-report-timers =
      lib.all
        (kind:
          let timer = on.systemd.timers."finance-signal-report@${kind}";
          in timer.wantedBy == [ "timers.target" ]
            && !timer.timerConfig.Persistent
            && timer.timerConfig.RandomizedDelaySec == 0
            && timer.timerConfig.AccuracySec == "1s"
            && timer.timerConfig.Unit == "finance-signal-report@${kind}.service"
            && timer.timerConfig.OnCalendar == (if kind == "daily"
          then "*-*-* 08:00,05,10:00 America/New_York"
          else "Fri *-*-* 16:00,05,10:00 America/New_York")) [ "daily" "weekly" ];
    monitor-is-independent-local-read-only =
      monitor.requires == [ ] && monitor.wants == [ ]
      && !(monitor.unitConfig ? AssertPathIsMountPoint)
      && monitor.serviceConfig.PrivateNetwork
      && monitor.serviceConfig.RestrictAddressFamilies == [ "AF_UNIX" ]
      && monitor.serviceConfig.BindReadOnlyPaths == [ "-${dbDir}" ]
      && monitor.serviceConfig.ReadWritePaths == [ "/run/finance-signal-metrics" ]
      && monitor.serviceConfig.TimeoutStartSec == "30s"
      && on.systemd.timers.finance-signal-metrics.timerConfig.OnUnitActiveSec == "2m";
    only-own-setgid-metrics-directory =
      builtins.elem "d /run/finance-signal-metrics 2750 homelab-mcp node-exporter -" on.systemd.tmpfiles.rules
      && builtins.elem "L+ /var/lib/node_exporter/textfile_collector/finance_signal.prom - - - - /run/finance-signal-metrics/finance_signal.prom" on.systemd.tmpfiles.rules;
    alerts-use-existing-high-route =
      lib.all (r: r.severity == "high" && r.labels.service == "finance-signal")
        (builtins.attrValues on.modules.alerting.rules);
  };
in
assert lib.assertMsg (lib.all (passed: passed) (builtins.attrValues checks))
  "finance-signal production contract failed: ${lib.concatStringsSep ", " (builtins.attrNames (lib.filterAttrs (_: passed: !passed) checks))}";
checks
