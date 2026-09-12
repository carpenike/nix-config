{ config, inputs, pkgs, lib, mylib, ... }:
let
  packages = inputs.atrium.packages.${pkgs.stdenv.hostPlatform.system};
  identity = import ../atrium/identity.nix { inherit lib; };
  runtime = import ../atrium/runtime.nix {
    inherit lib;
    policyPath =
      if config.services.atrium.enable
      then "/etc/atrium/desired-state/resolver.json"
      else "/var/lib/atrium-policy/resolver.json";
  };
  ids = mylib.serviceUids;
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  enabled = config.services.atriumForge.enable;
  resolver = lib.getExe packages.resolver;
  json = value: builtins.toJSON value;
  loadCredentials = values: lib.mapAttrsToList (name: path: "${name}:${path}") values;
  hardened = {
    NoNewPrivileges = true;
    PrivateTmp = true;
    PrivateDevices = true;
    ProtectSystem = "strict";
    ProtectHome = true;
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectControlGroups = true;
    ProtectProc = "invisible";
    RestrictSUIDSGID = true;
    LockPersonality = true;
    CapabilityBoundingSet = [ "" ];
    AmbientCapabilities = [ "" ];
    RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
    UMask = "0077";
    UnsetEnvironment = [ "SSLKEYLOGFILE" "HTTP_PROXY" "HTTPS_PROXY" "ALL_PROXY" ];
  };
  mounted = paths: {
    after = [ "zfs-service-datasets.service" ];
    requires = [ "zfs-service-datasets.service" ];
    unitConfig.RequiresMountsFor = paths;
  };
  privateState = user: hardened // {
    User = user;
    Group = user;
    StateDirectory = user;
    StateDirectoryMode = "0700";
    ReadWritePaths = [ "/var/lib/${user}" ];
  };
  serve = unit: command: port: (mounted [
    runtime.paths.resolver
    runtime.paths.trust
    runtime.paths.policy
  ]) // {
    description = "Atrium ${command} with explicit identity and policy initialization";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [ "zfs-service-datasets.service" "network-online.target" "firewall.service" ];
    unitConfig = {
      RequiresMountsFor = [ runtime.paths.resolver runtime.paths.trust runtime.paths.policy ];
      AssertPathExists = [
        "${runtime.paths.resolver}/foundation.initialized"
        "${runtime.paths.resolver}/resolver.sqlite3"
        runtime.resolver.policy_path
      ];
      AssertFileNotEmpty = [
        "${runtime.paths.resolver}/foundation.initialized"
        "${runtime.paths.resolver}/resolver.sqlite3"
        runtime.resolver.policy_path
      ];
    };
    serviceConfig = (privateState "atrium-resolver") // {
      ExecStart = "${resolver} --config /etc/atrium/runtime/${unit}.json ${command} --port ${toString port}";
      LoadCredential = loadCredentials runtime.deviceCredentials;
      ReadOnlyPaths = [ runtime.paths.policy ];
      Restart = "on-failure";
      RestartSec = "10s";
    };
  };
  outputRule = port: uid:
    "-o lo -d 127.0.0.1 -p tcp --dport ${toString port} -m owner ! --uid-owner ${toString uid} -j REJECT --reject-with tcp-reset";
  outputRules = [
    (outputRule runtime.ports.resolver ids.caddy.uid)
    (outputRule runtime.ports.registration ids.atrium-registration.uid)
  ];
  states = {
    atrium-resolver = { owner = "atrium-resolver"; mode = "0700"; };
    atrium-trust = { owner = "atrium-trust"; mode = "0700"; };
    atrium-policy = { owner = "root"; mode = "0755"; };
  };
in
{
  imports = [ inputs.atrium.nixosModules.atrium ];
  options.services.atriumForge.enable =
    lib.mkEnableOption "Forge's Atrium foundation custody and protected entrypoints";

  config = lib.mkMerge [
    {
      services.atriumForge.enable = lib.mkDefault true;
      services.atrium.enable = lib.mkDefault (enabled && config.services.atrium.registry != null);
      services.atrium.litellmVersion = "v1.100.1";
      services.atrium.runtime = {
        resolver.package = packages.resolver;
        reconciler = {
          package = packages.atrium-litellm-controller;
          executable = "atrium-litellm-controller";
        };
      };
      # The full registry cannot be published until provider-account/alias ownership
      # is supplied. Its validator is not weakened to manufacture a model-free one.
      # A supplied complete registry uses the app generator; without one, the
      # explicit external policy path remains a fatal startup prerequisite.
    }
    (lib.mkIf enabled {
      assertions = [
        {
          assertion = config.networking.hostName == "forge"
            && config.networking.domain == "holthome.net";
          message = "Atrium runtime values are specific to Forge at holthome.net.";
        }
        {
          assertion = !config.services.atrium.runtime.resolver.enable
            && !config.services.atrium.runtime.reconciler.enable;
          message = "Forge owns these runtime units; do not enable duplicate generic app runtime units.";
        }
        {
          assertion = config.services.atrium.registry == null
            || config.services.atrium.registry.environment == "production";
          message = "Forge must never publish an isolated or synthetic registry as production policy.";
        }
        {
          assertion = config.networking.firewall.enable && !config.networking.nftables.enable;
          message = "Atrium's scoped loopback boundary uses Forge's existing iptables firewall.";
        }
      ];

      environment.systemPackages = [
        packages.resolver
        packages.atrium-litellm-controller
      ];
      environment.etc = {
        "atrium/bootstrap/identity.json".source = ../atrium/identity-bootstrap.json;
        "atrium/bootstrap/resolver.json".text = json identity.settings;
        "atrium/bootstrap/foundation.json".text = json runtime.bootstrap;
        "atrium/bootstrap/tls-plan.json".text = json runtime.tlsPlan;
        "atrium/bootstrap/registry-base.json".text = json
          (import ../atrium/registry-base.nix { inherit lib; homelabMcp = inputs.homelab-mcp; });
        "atrium/runtime/atrium-resolver.json".text = json runtime.resolver;
        "atrium/runtime/atrium-device-registration.json".text = json runtime.registration;
        "atrium/runtime/adoption.json".text = json runtime.adoption;
      };

      users.users = lib.genAttrs [ "atrium-resolver" "atrium-trust" "atrium-registration" ]
        (name: {
          isSystemUser = true;
          uid = ids.${name}.uid;
          group = name;
          extraGroups = ids.${name}.extraGroups;
        });
      users.groups = lib.genAttrs [ "atrium-resolver" "atrium-trust" "atrium-registration" ]
        (name: { gid = ids.${name}.gid; });

      systemd.services = {
        atrium-resolver = serve "atrium-resolver" "serve" runtime.ports.resolver;
        atrium-device-registration = serve "atrium-device-registration" "serve-devices" runtime.ports.registration;

        # Deliberately not wanted/required by startup units. Neither initialization
        # command may run automatically on boot, deploy, missing state, or recovery.
        atrium-initialize = (mounted [ runtime.paths.resolver ]) // {
          description = "Explicit first-use Atrium owner identity and signing initialization";
          script = ''
            set -eu
            test ! -e ${runtime.paths.resolver}/foundation.initialized
            test ! -e ${runtime.paths.resolver}/resolver.sqlite3
            ${resolver} --config /etc/atrium/bootstrap/foundation.json bootstrap \
              --enrollment /etc/atrium/bootstrap/identity.json
            ${resolver} --config /etc/atrium/bootstrap/foundation.json signing initialize
            set -C
            printf '%s\n' '${runtime.installation}' > ${runtime.paths.resolver}/foundation.initialized
          '';
          serviceConfig = (privateState "atrium-resolver") // {
            Type = "oneshot";
            PrivateNetwork = true;
          };
        };
        atrium-trust-initialize = (mounted [ runtime.paths.trust ]) // {
          description = "Explicit first-use Atrium TLS authorities and exact service identities";
          serviceConfig = (privateState "atrium-trust") // {
            Type = "oneshot";
            PrivateNetwork = true;
            ExecStart = "${resolver} --config /etc/atrium/bootstrap/foundation.json tls --plan /etc/atrium/bootstrap/tls-plan.json initialize";
          };
        };
        atrium-trust-check = (mounted [ runtime.paths.trust ]) // {
          description = "Validate Atrium private TLS custody without replacing or resetting it";
          serviceConfig = (privateState "atrium-trust") // {
            Type = "oneshot";
            PrivateNetwork = true;
            ExecStart = "${resolver} --config /etc/atrium/bootstrap/foundation.json tls --plan /etc/atrium/bootstrap/tls-plan.json status";
            StandardOutput = "null";
          };
        };
        atrium-registration-entry = {
          description = "LAN-only Atrium registration with end-to-end device mTLS";
          after = [ "network-online.target" "firewall.service" "atrium-device-registration.service" ];
          wants = [ "network-online.target" ];
          requires = [ "atrium-device-registration.service" ];
          wantedBy = [ "multi-user.target" ];
          serviceConfig = hardened // {
            User = "atrium-registration";
            Group = "atrium-registration";
            ExecStart = "${pkgs.socat}/bin/socat TCP4-LISTEN:${toString runtime.ports.registrationEntry},bind=${runtime.registrationAddress},reuseaddr,fork TCP4:127.0.0.1:${toString runtime.ports.registration}";
            Restart = "on-failure";
            RestartSec = "10s";
          };
        };
      };
      systemd.timers.atrium-trust-check = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "5m";
          OnUnitActiveSec = "1h";
          Unit = "atrium-trust-check.service";
        };
      };

      networking.firewall = {
        interfaces.${runtime.registrationInterface}.allowedTCPPorts = [ runtime.ports.registrationEntry ];
        extraCommands = lib.concatMapStringsSep "\n"
          (rule: ''
            ${pkgs.iptables}/bin/iptables -C OUTPUT ${rule} 2>/dev/null \
              || ${pkgs.iptables}/bin/iptables -I OUTPUT ${rule}
          '')
          outputRules;
        extraStopCommands = lib.concatMapStringsSep "\n"
          (rule: "${pkgs.iptables}/bin/iptables -D OUTPUT ${rule} 2>/dev/null || true")
          outputRules;
      };
      modules.services.caddy.virtualHosts.atrium = (import ../atrium/entry.nix { inherit runtime; }) // {
        enable = true;
        hostName = "atrium.holthome.net";
        cloudflare = { enable = true; tunnel = "forge"; };
      };
      modules.services.caddy.virtualHosts.homelab-mcp = lib.mkIf config.services.homelab-mcp.enable {
        extraConfig = lib.mkAfter ''
          @atrium_service_only path /cc/issue /cc/issue/* /v1/native-policy /v1/native-policy/*
          respond @atrium_service_only 404
        '';
        reverseProxyBlock = lib.mkAfter (import ../atrium/headers.nix);
      };
      modules.services.caddy.virtualHosts.whiskeywhiskeywhiskey =
        lib.mkIf config.services.whiskey-whiskey-whiskey.enable {
          reverseProxyBlock = lib.mkAfter (import ../atrium/headers.nix);
        };

      modules.storage.datasets.services = lib.mapAttrs
        (name: state: {
          mountpoint = "/var/lib/${name}";
          inherit (state) owner mode;
          group = state.owner;
          recordsize = "16K";
          compression = "zstd";
          properties = {
            atime = "off";
            "com.sun:auto-snapshot" = "true";
          };
          protection = {
            class = "critical";
            objectives = {
              onsiteRpoSeconds = 900;
              offsiteRpoSeconds = 86400;
              rtoSeconds = 7200;
            };
            requiredTiers = [ "local-snapshot" "replication" "nas-backup" "offsite-backup" ];
            consistency = "crash-consistent";
            validator = null;
            allowEmptyBootstrap = false;
          };
        })
        states;
      modules.backup.sanoid.datasets = lib.mapAttrs'
        (name: _: lib.nameValuePair "tank/services/${name}" (forgeDefaults.mkSanoidDataset name))
        states;
      modules.services.backup.restic.jobs = lib.concatMapAttrs
        (name: _: {
          ${name} = (forgeDefaults.mkBackupWithTags name [ "atrium" "authorization-state" "forge" ]) // {
            paths = [ "/var/lib/${name}" ];
          };
          "${name}-offsite" = (forgeDefaults.mkBackupWithTags name [ "atrium" "authorization-state" "offsite" "forge" ]) // {
            repository = "r2-offsite";
            paths = [ "/var/lib/${name}" ];
          };
        })
        states;
      modules.alerting.rules = lib.mapAttrs
        (unit: label: forgeDefaults.mkSystemdServiceDownAlert unit label "wing authorization foundation")
        {
          atrium-resolver = "AtriumResolver";
          atrium-device-registration = "AtriumDeviceRegistration";
          atrium-registration-entry = "AtriumRegistrationEntry";
        } // {
        atrium-trust-check-failed = {
          type = "promql";
          alertname = "AtriumTrustCheckFailed";
          expr = ''node_systemd_unit_state{name="atrium-trust-check.service",state="failed"} == 1'';
          for = "2m";
          severity = "high";
          labels = { service = "atrium-trust"; category = "security"; };
          annotations = {
            summary = "Atrium private TLS custody is missing, invalid, or expired";
            description = "Use the independent Forge operator path; never erase or regenerate existing trust state.";
            command = "systemctl status atrium-trust-check.service";
          };
        };
      };
      modules.services.gatus.contributions.atrium = {
        name = "Atrium foundation";
        group = "applications";
        url = "${runtime.endpoints.resolver}/healthz";
        interval = "60s";
        conditions = [ "[STATUS] == 200" "[BODY].status == ok" "[RESPONSE_TIME] < 5000" ];
        alerts = [{
          type = "pushover";
          sendOnResolved = true;
          failureThreshold = 3;
          successThreshold = 1;
        }];
      };
    })
  ];
}
