{ inputs }:
let
  inherit (inputs.nixpkgs) lib;
  pkgs = inputs.nixpkgs.legacyPackages.x86_64-linux;
  module = ../../hosts/forge/services/finance-signal.nix;
  mkHost =
    { reader ? false
    , capture ? false
    , version ? "0.33.1"
    , secret ? true
    , allowedUsers ? [ "homelab-mcp" ]
    }:
    (lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        module
        ({ lib, ... }: {
          options = {
            services.homelab-mcp = lib.mkOption { type = lib.types.attrsOf lib.types.anything; };
            modules.services.signal-api = lib.mkOption { type = lib.types.attrsOf lib.types.anything; };
            modules.services.postgresql.databases = lib.mkOption {
              type = lib.types.attrsOf lib.types.anything;
              default = { };
            };
            modules.services.backup.restic.jobs = lib.mkOption { type = lib.types.attrsOf lib.types.anything; };
            modules.storage.datasets.services = lib.mkOption { type = lib.types.attrsOf lib.types.anything; };
            sops.secrets = lib.mkOption { type = lib.types.attrsOf lib.types.anything; default = { }; };
          };
          config = {
            system.stateVersion = "26.05";
            boot.isContainer = true;
            services.financeSignalStaging = {
              reportReader.enable = reader;
              capture.enable = capture;
            };
            services.homelab-mcp = {
              enable = true;
              package = pkgs.emptyDirectory // { inherit version; };
              environmentFile = "/run/secrets/homelab-mcp/env";
            };
            modules.services = {
              signal-api = {
                enable = true;
                port = 18484;
                localAccess = { enable = true; subnet = "10.90.0.0/24"; inherit allowedUsers; };
              };
              postgresql.databases.homelab_finance = {
                owner = "homelab-mcp-export";
                permissionsPolicy = "owner-only";
              };
              backup.restic.jobs = {
                homelab-mcp.enable = true;
                homelab-mcp-offsite.enable = true;
              };
            };
            modules.storage.datasets.services.homelab-mcp.mountpoint = "/var/lib/homelab-mcp";
            sops.secrets = lib.optionalAttrs secret {
              "homelab-mcp/finance-signal-env" = {
                path = "/run/secrets/homelab-mcp/finance-signal-env";
                owner = "root";
                mode = "0400";
              };
            };
            users.users.homelab-mcp = { isSystemUser = true; group = "homelab-mcp"; };
            users.groups.homelab-mcp = { };
            systemd.services.homelab-mcp = {
              environment = {
                HOMELAB_MCP_FINANCES_CONTEXT_DB_PATH = "/var/lib/homelab-mcp/finances-context.db";
                HOMELAB_MCP_FINANCES_SIDECAR_BASE_URL = "http://127.0.0.1:19210";
                HOMELAB_MCP_FINANCES_REPO_URL = "https://example.invalid/finances.git";
                HOMELAB_MCP_UNRELATED_SETTING = "must-not-reach-reader-or-capture";
              };
              serviceConfig = {
                ExecStart = "${pkgs.coreutils}/bin/true";
                User = "homelab-mcp";
                Group = "homelab-mcp";
                EnvironmentFile = [
                  "/run/secrets/homelab-mcp/env"
                  "/run/secrets-rendered/effective-additional-env"
                ];
              };
            };
          };
        })
      ];
    }).config;
  off = mkHost { version = "0.32.0"; secret = false; };
  on = mkHost { reader = true; capture = true; };
  readerOnly = mkHost { reader = true; secret = false; };
  captureOnly = mkHost { capture = true; };
  old = mkHost { reader = true; version = "0.32.0"; };
  declaredTransport = mkHost { capture = true; secret = false; };
  blockedUid = mkHost { capture = true; allowedUsers = [ "hermes" ]; };
  stagingAssertionsPass = c: lib.all
    (a: a.assertion || !(lib.hasPrefix "finance-signal staging" a.message))
    c.assertions;
  projector = on.systemd.services.finance-report-reader-config;
  prepare = on.systemd.services."finance-report-prepare@";
  capture = on.systemd.services.finance-signal-capture-staging;
  status = on.systemd.services.finance-signal-staging-status;
  preview = on.systemd.services."finance-signal-report-preview@";
  database = on.modules.services.postgresql.databases.homelab_finance;
  role = "finance-report-reader";
  newUnits = [
    "finance-report-reader-config"
    "finance-report-prepare@"
    "finance-signal-capture-staging"
    "finance-signal-staging-status"
    "finance-signal-report-preview@"
  ];
  checks = {
    real-secret-and-transport-units-order-startup =
      builtins.elem "sops-install-secrets.service" projector.after
      && builtins.elem "sops-install-secrets.service" projector.requires
      && builtins.elem "sops-install-secrets.service" capture.after
      && builtins.elem "sops-install-secrets.service" capture.requires
      && builtins.elem "podman-signal-api.service" capture.requires
      && !(builtins.elem "sops-nix.service" capture.after);
    off-means-no-units-secrets-roles-or-bootstrap =
      lib.all (name: !(builtins.hasAttr name off.systemd.services)) newUnits
      && off.sops.secrets == { }
      && !(off.modules.services.postgresql.databases.homelab_finance ? additionalRoles)
      && stagingAssertionsPass off;
    independent-gates-do-not-need-unrelated-credentials =
      stagingAssertionsPass readerOnly && stagingAssertionsPass captureOnly
      && !(readerOnly.systemd.services ? finance-signal-capture-staging)
      && !(captureOnly.systemd.services ? finance-report-reader-config)
      && !(captureOnly.modules.services.postgresql.databases.homelab_finance ? additionalRoles);
    ops-preview-is-explicit-manual-and-isolated =
      !(readerOnly.systemd.services ? "finance-signal-report-preview@")
      && !(captureOnly.systemd.services ? "finance-signal-report-preview@")
      && lib.hasSuffix
        " report-preview ${on.services.homelab-mcp.package}/bin/homelab-finances-signal-report %i 18484"
        preview.serviceConfig.ExecStart
      && preview.serviceConfig.EnvironmentFile == [ "/run/secrets/homelab-mcp/finance-signal-env" ]
      && preview.serviceConfig.ReadWritePaths == [
        "/var/lib/homelab-mcp/finance-reports"
        "/var/lib/homelab-mcp/finance-signal-staging"
      ]
      && preview.serviceConfig.Restart == "no"
      && preview.serviceConfig.TimeoutStartSec == "270s"
      && builtins.elem "finance-report-reader-config.service" preview.requires;
    release-and-uid-guards-fail-closed =
      stagingAssertionsPass on
      && !(stagingAssertionsPass old)
      && !(stagingAssertionsPass blockedUid);
    transport-declaration-exists-only-after-capture-gate =
      stagingAssertionsPass declaredTransport
      && readerOnly.sops.secrets == { }
      && builtins.attrNames declaredTransport.sops.secrets == [ "homelab-mcp/finance-signal-env" ]
      && declaredTransport.sops.secrets."homelab-mcp/finance-signal-env".owner == "root"
      && declaredTransport.sops.secrets."homelab-mcp/finance-signal-env".group == "root"
      && declaredTransport.sops.secrets."homelab-mcp/finance-signal-env".mode == "0400";
    dedicated-peer-role-not-writer-or-global-reader =
      database.owner == "homelab-mcp-export"
      && database.permissionsPolicy == "owner-only"
      && database.additionalRoles.${role} == { passwordFile = null; grantRoles = [ ]; }
      && database.databasePermissions.${role} == [ "CONNECT" ]
      && database.schemaPermissions.household_finance.${role} == [ "USAGE" ]
      && database.tablePermissions == {
        "household_finance.money_overview".${role} = [ "SELECT" ];
        "household_finance.export_runs".${role} = [ "SELECT" ];
      }
      && !(database ? defaultPrivileges)
      && lib.hasInfix "local homelab_finance finance-report-reader peer map=finance-report" on.services.postgresql.authentication
      && lib.hasInfix "finance-report homelab-mcp finance-report-reader" on.services.postgresql.identMap;
    root-projection-only-reuses-all-effective-mcp-inputs =
      projector.serviceConfig.User == "root"
      && projector.environment == on.systemd.services.homelab-mcp.environment
      && projector.serviceConfig.EnvironmentFile == on.systemd.services.homelab-mcp.serviceConfig.EnvironmentFile
      && lib.all (name: builtins.elem name projector.serviceConfig.UnsetEnvironment)
        [ "LD_PRELOAD" "LD_LIBRARY_PATH" "LD_AUDIT" "GCONV_PATH" "PYTHONPATH" "PYTHONHOME" ]
      && projector.serviceConfig.PrivateNetwork
      && projector.serviceConfig.RestrictAddressFamilies == [ "AF_UNIX" ]
      && projector.serviceConfig.ReadWritePaths == [ "/run/finance-report-reader" ]
      && projector.serviceConfig.RuntimeDirectoryMode == "0700"
      && projector.serviceConfig.RuntimeDirectoryPreserve
      && !(projector.serviceConfig.RemainAfterExit or false)
      && lib.hasInfix "/bin/python3 -I -B " projector.serviceConfig.ExecStart
      && lib.hasSuffix "runtime.py project" projector.serviceConfig.ExecStart;
    no-timers-boot-activation-or-implicit-preparation =
      lib.all
        (name: on.systemd.services.${name}.wantedBy == [ ]
        && on.systemd.services.${name}.requiredBy == [ ])
        newUnits
      && lib.all (name: !(builtins.hasAttr name on.systemd.timers)) newUnits
      && lib.all (rule: !(lib.hasInfix "finance-report" rule) && !(lib.hasInfix "finance-signal" rule)) on.systemd.tmpfiles.rules
      && !(capture.serviceConfig ? ExecStartPre)
      && !(capture.serviceConfig ? ExecStartPost);
    generated-units-render-without-install-hooks =
      lib.all
        (name:
          let text = on.systemd.units."${name}.service".text;
          in lib.hasInfix "ExecStart=" text && !(lib.hasInfix "WantedBy=" text)
            && !(lib.hasInfix "RequiredBy=" text))
        newUnits;
    native-is-manual-private-and-has-no-environment-files =
      prepare.serviceConfig.User == "homelab-mcp"
      && prepare.serviceConfig.UMask == "0077"
      && !(prepare.serviceConfig ? EnvironmentFile)
      && !(prepare.environment ? HOMELAB_MCP_UNRELATED_SETTING)
      && prepare.serviceConfig.StateDirectory == "homelab-mcp/finance-reports"
      && prepare.serviceConfig.StateDirectoryMode == "0700"
      && prepare.serviceConfig.ReadWritePaths == [ "/var/lib/homelab-mcp/finance-reports" ]
      && prepare.serviceConfig.BindReadOnlyPaths == [
        "/var/lib/homelab-mcp/finances-ingest"
        "/run/finance-report-reader"
        "/run/postgresql"
      ]
      && prepare.serviceConfig.TemporaryFileSystem == [ "/var/lib:ro" "/run:ro" ]
      && prepare.serviceConfig.StandardOutput == "null"
      && builtins.elem "finance-report-reader-config.service" prepare.requires
      && prepare.serviceConfig.Restart == "no";
    capture-has-only-dedicated-transport-and-staging-writes =
      capture.serviceConfig.User == "homelab-mcp"
      && capture.serviceConfig.Group == "homelab-mcp"
      && capture.serviceConfig.EnvironmentFile == [ "/run/secrets/homelab-mcp/finance-signal-env" ]
      && !(capture.environment ? HOMELAB_MCP_UNRELATED_SETTING)
      && capture.serviceConfig.StateDirectory == "homelab-mcp/finance-signal-staging"
      && capture.serviceConfig.StateDirectoryMode == "0700"
      && capture.serviceConfig.ReadWritePaths == [ "/var/lib/homelab-mcp/finance-signal-staging" ]
      && capture.serviceConfig.BindPaths == [ "/var/lib/homelab-mcp/finance-signal-staging" ]
      && capture.serviceConfig.TemporaryFileSystem == [ "/var/lib:ro" "/run:ro" ]
      && builtins.elem "-/run/secrets" capture.serviceConfig.InaccessiblePaths
      && builtins.elem "-/run/finance-report-reader" capture.serviceConfig.InaccessiblePaths
      && lib.hasSuffix "/bin/homelab-finances-signal 18484" capture.serviceConfig.ExecStart;
    capture-supervision-and-network-are-bounded =
      capture.serviceConfig.UMask == "0077"
      && capture.serviceConfig.Restart == "on-failure"
      && capture.serviceConfig.RestartSec == "30s"
      && capture.unitConfig.StartLimitIntervalSec == 600
      && capture.unitConfig.StartLimitBurst == 3
      && capture.serviceConfig.TimeoutStopSec == "60s"
      && capture.serviceConfig.KillMode == "control-group"
      && capture.serviceConfig.IPAddressDeny == "any"
      && capture.serviceConfig.IPAddressAllow == [ "127.0.0.1/32" "::1/128" "10.90.0.0/24" ];
    persistent-consumers-require-existing-mcp-mount =
      lib.all
        (unit:
          unit.unitConfig.RequiresMountsFor == [ "/var/lib/homelab-mcp" ]
          && unit.unitConfig.AssertPathIsMountPoint == [ "/var/lib/homelab-mcp" ]
          && builtins.elem "zfs-service-datasets.service" unit.requires)
        [ prepare capture status ];
    status-is-network-free-credential-free-and-does-not-initialize =
      lib.hasSuffix " status --database /var/lib/homelab-mcp/finance-signal-staging/context.db" status.serviceConfig.ExecStart
      && status.serviceConfig.PrivateNetwork
      && !(status.serviceConfig ? EnvironmentFile)
      && !(status.serviceConfig ? StateDirectory)
      && !(status.serviceConfig ? ReadWritePaths)
      && status.serviceConfig.BindReadOnlyPaths == [ "-/var/lib/homelab-mcp/finance-signal-staging" ]
      && status.serviceConfig.TemporaryFileSystem == [ "/var/lib:ro" "/run:ro" ];
  };
  failed = builtins.attrNames (lib.filterAttrs (_: passed: !passed) checks);
in
assert lib.assertMsg (failed == [ ]) "Finance signal staging regressions: ${lib.concatStringsSep ", " failed}";
checks
