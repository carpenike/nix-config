{ config, inputs, pkgs, lib, mylib, ... }:
let
  cfg = config.services.atriumForge;
  composition = import ../atrium/configuration.nix { inherit config inputs pkgs lib mylib; };
  inherit (composition) packages runtime;
  m = composition.models;
  enabled = cfg.enable;
  adopted = enabled && cfg.adoption.models;
  projection = import ../atrium/credential-projection.nix { inherit lib; };
  credentials = values: lib.mapAttrsToList (name: path: "${name}:${path}") values;
  projectedCredentials = unit: values:
    (projection.serviceConfig { inherit pkgs unit; credentials = values; }) // {
      LoadCredential = credentials values;
    };
  reconcilerProjection = projectedCredentials "atrium-reconciler" m.controllerCredentials;
  python = pkgs.python312.withPackages (ps: [
    (ps.toPythonModule packages.resolver)
    (ps.toPythonModule packages.credential-profiles)
    (ps.toPythonModule packages.atrium-litellm-controller)
    (ps.toPythonModule packages.atrium-litellm-admission)
  ]);
  bootstrapProgram = "${python}/bin/python ${../atrium/model-bootstrap.py}";
  controllerConfig = "/etc/atrium/runtime/model-controller.json";
  controllerInitializeConfig = "/etc/atrium/bootstrap/model-controller.json";
  resolverInitializeConfig = "/etc/atrium/bootstrap/model-resolver.json";
  resolverInitializeSettings = runtime.resolver // {
    devices = null;
    home_mcp = null;
    native_policy = null;
    litellm = m.resolver // {
      controller_key_file = projection.path "atrium-model-resolver-initialize" "model-management";
    };
  };
  hardened = {
    NoNewPrivileges = true;
    PrivateTmp = true;
    PrivateDevices = true;
    ProtectSystem = "strict";
    ProtectHome = true;
    ProtectProc = "invisible";
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectControlGroups = true;
    RestrictSUIDSGID = true;
    LockPersonality = true;
    CapabilityBoundingSet = [ "" ];
    AmbientCapabilities = [ "" ];
    UMask = "0077";
    UnsetEnvironment = [ "SSLKEYLOGFILE" "HTTP_PROXY" "HTTPS_PROXY" "ALL_PROXY" ];
  };
  stateUnit = role: {
    after = [ "zfs-service-datasets.service" ];
    requires = [ "zfs-service-datasets.service" ];
    unitConfig.RequiresMountsFor = [ "/var/lib/${role.name}" runtime.paths.policy ];
    serviceConfig = hardened // {
      User = role.name;
      Group = role.name;
      StateDirectory = role.name;
      StateDirectoryMode = "0700";
    };
  };
  management = lib.getExe packages.atrium-litellm-controller;
  admission = lib.getExe packages.atrium-litellm-admission;
  packageMount = package: destination:
    "${package}/${pkgs.python312.sitePackages}:${destination}:ro";
  firewallRule = "-o lo -d 127.0.0.1 -p tcp --dport 4100 -m owner ! --uid-owner ${toString mylib.serviceUids.caddy.uid} -j REJECT --reject-with tcp-reset";
  failedAlert = unit: summary: {
    type = "promql";
    alertname = "Atrium${unit}Failed";
    expr = ''node_systemd_unit_state{name="${unit}.service",state="failed"} == 1'';
    for = "1m";
    severity = "high";
    labels = { service = "atrium-models"; category = "security"; };
    annotations = {
      inherit summary;
      description = "Preserve ownership, delivery and deny history. Use the independent Forge operator path; never reset state to recover availability.";
      command = "systemctl status ${unit}.service";
    };
  };
in
{
  imports = [ inputs.atrium.nixosModules.litellm-admission ];
  config = lib.mkMerge [
    (lib.mkIf enabled {
      assertions = [
        {
          assertion = lib.length (lib.unique (map (role: role.uid) (builtins.attrValues m.roles))) == 4
            && m.metadataGroup.gid != m.deliveryGroup.gid;
          message = "Atrium model producers, gateway and consumer require distinct UIDs and separate metadata/token groups.";
        }
        {
          assertion = m.controllerCredentials.personal-anthropic != m.controllerCredentials.family-anthropic
            && m.controllerCredentials.management != m.resolverCredentials.model-management;
          message = "Atrium requires distinct wing inference sources and separate controller/resolver management sources.";
        }
      ];
      users.groups = {
        atrium-reconciler.gid = m.roles.controller.gid;
        atrium-model-gateway.gid = m.roles.gateway.gid;
        atrium-model-metadata.gid = m.metadataGroup.gid;
        atrium-whiskey-delivery.gid = m.deliveryGroup.gid;
      };
      users.users = {
        atrium-resolver.extraGroups = [ m.metadataGroup.name ];
        atrium-reconciler = {
          isSystemUser = true;
          uid = m.roles.controller.uid;
          group = m.roles.controller.name;
          extraGroups = [ m.metadataGroup.name m.deliveryGroup.name ];
        };
        atrium-model-gateway = {
          isSystemUser = true;
          uid = m.roles.gateway.uid;
          group = m.roles.gateway.name;
          extraGroups = [ m.metadataGroup.name ];
        };
      };
      systemd.tmpfiles.rules = [
        "d /run/atrium-publications 0755 root root -"
        "d ${m.exports.resolver} 2750 ${m.roles.resolver.name} ${m.metadataGroup.name} -"
        "d ${m.exports.controller} 2750 ${m.roles.controller.name} ${m.metadataGroup.name} -"
        "d ${m.private.resolver} 0700 ${m.roles.resolver.name} ${m.roles.resolver.name} -"
        "d ${m.private.gateway}/config 0700 ${m.roles.gateway.name} ${m.roles.gateway.name} -"
        "d ${m.private.gateway}/admission 0700 ${m.roles.gateway.name} ${m.roles.gateway.name} -"
        "d ${m.private.gateway}/scratch 0700 ${m.roles.gateway.name} ${m.roles.gateway.name} -"
        "d /run/atrium-delivery 0755 root root -"
        "d /run/atrium-delivery/whiskey 2750 ${m.roles.controller.name} ${m.deliveryGroup.name} -"
        "d /run/atrium-acknowledgements 0755 root root -"
      ];
      environment.etc = {
        "atrium/runtime/model-controller.json".text = builtins.toJSON m.controller;
        "atrium/runtime/model-admission.json".text = builtins.toJSON m.admission;
        "atrium/runtime/whiskey-model.json".text = builtins.toJSON m.whiskey;
        "atrium/bootstrap/model-controller.json".text = builtins.toJSON
          (m.controllerFor "atrium-model-controller-initialize");
        "atrium/bootstrap/model-resolver.json".text = builtins.toJSON resolverInitializeSettings;
      };
      environment.systemPackages = [ packages.atrium-litellm-admission ];
      systemd.services = {
        atrium-model-policy = {
          description = "Publish only the Nix-generated model policy with root provenance";
          after = [ "zfs-service-datasets.service" ];
          requires = [ "zfs-service-datasets.service" ];
          restartTriggers = [ config.services.atrium.generated.resolver ];
          unitConfig.RequiresMountsFor = [ runtime.paths.policy ];
          script = ''
            set -eu
            ${pkgs.coreutils}/bin/install -m 0640 -g ${m.metadataGroup.name} \
              ${config.services.atrium.generated.resolver} ${m.policyPath}.new
            ${pkgs.coreutils}/bin/mv -T ${m.policyPath}.new ${m.policyPath}
          '';
          serviceConfig = hardened // {
            Type = "oneshot";
            RemainAfterExit = true;
            User = "root";
            SupplementaryGroups = [ m.metadataGroup.name ];
            ReadWritePaths = [ runtime.paths.policy ];
            PrivateNetwork = true;
          };
        };
        atrium-admission-settings = lib.recursiveUpdate (stateUnit m.roles.gateway) {
          description = "Install static admission settings as their actual gateway reader";
          restartTriggers = [ config.environment.etc."atrium/runtime/model-admission.json".source ];
          script = ''
            set -eu
            ${pkgs.coreutils}/bin/install -m 0600 /etc/atrium/runtime/model-admission.json ${m.admissionSettingsPath}.new
            ${pkgs.coreutils}/bin/mv -T ${m.admissionSettingsPath}.new ${m.admissionSettingsPath}
          '';
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ReadWritePaths = [ "${m.private.gateway}/config" ];
            PrivateNetwork = true;
          };
        };
        atrium-model-resolver-initialize = lib.recursiveUpdate (stateUnit m.roles.resolver) {
          description = "Explicit first-use R06 publication history, from real resolver state";
          unitConfig.AssertFileNotEmpty = [
            "${runtime.paths.resolver}/foundation.initialized"
            "${runtime.paths.resolver}/resolver.sqlite3"
          ];
          serviceConfig = projectedCredentials "atrium-model-resolver-initialize" m.resolverCredentials // {
            Type = "oneshot";
            PrivateNetwork = true;
            ReadWritePaths = [ runtime.paths.resolver m.exports.resolver ];
            ExecStart = "${bootstrapProgram} resolver --config ${resolverInitializeConfig} --confirm-new-installation ${runtime.installation}";
          };
        };
        atrium-model-controller-initialize = lib.recursiveUpdate (stateUnit m.roles.controller) {
          description = "Explicit first-use N04 ownership ledger and real service publication";
          unitConfig.AssertFileNotEmpty = [ "${m.exports.resolver}/associations.json" ];
          serviceConfig = projectedCredentials "atrium-model-controller-initialize"
            { inherit (m.controllerCredentials) management; } // {
            Type = "oneshot";
            PrivateNetwork = true;
            SupplementaryGroups = [ m.metadataGroup.name m.deliveryGroup.name ];
            ReadWritePaths = [ m.private.controller m.exports.controller ];
            ReadOnlyPaths = [ m.exports.resolver ];
            ExecStart = "${bootstrapProgram} controller --config ${controllerInitializeConfig} --confirm-new-installation ${runtime.installation}";
          };
        };
        atrium-model-admission-initialize = lib.recursiveUpdate (stateUnit m.roles.gateway) {
          description = "Explicit first-use N05 deny and ownership history";
          requires = [ "zfs-service-datasets.service" "atrium-admission-settings.service" "atrium-model-policy.service" ];
          after = [ "zfs-service-datasets.service" "atrium-admission-settings.service" "atrium-model-policy.service" ];
          serviceConfig = {
            Type = "oneshot";
            PrivateNetwork = true;
            ReadWritePaths = [ "${m.private.gateway}/admission" ];
            ExecStart = "${admission} --settings ${m.admissionSettingsPath} initialize";
          };
        };
      };
    })
    (lib.mkIf (config.modules.services.litellm.enable && !adopted) {
      # An operator approval marker is durable. Removing an adoption flag must
      # not silently run still-valid owned keys without request admission.
      systemd.services.podman-litellm.unitConfig.AssertPathExists = [
        "!/var/lib/atrium-policy/model-adoption.approved"
      ];
    })
    (lib.mkIf adopted {
      services.atriumLitellmAdmission = {
        enable = true;
        environment = "production";
        isolatedHarness = false;
        package = packages.atrium-litellm-admission;
        settingsFile = m.admissionSettingsPath;
      };
      assertions = [{
        assertion = config.modules.services.litellm.enable
          && config.modules.services.litellm.image == runtime.adoption.models.image
          && config.modules.services.litellm.podmanNetwork == null
          && lib.all
          (name: config.modules.services.litellm.routerSettings.${name} == m.routerSettings.${name})
          (builtins.attrNames m.routerSettings);
        message = "Atrium model adoption requires the pinned shared gateway, the complete controller routing contract, and its explicit private host-network boundary.";
      }];
      modules.services.litellm = {
        routerSettings = lib.mapAttrs (_: value: lib.mkForce value) m.routerSettings;
        healthUrl = "${runtime.endpoints.models}/health/liveliness";
        publishPort = false;
        internalPort = 4100;
        listenAddress = "127.0.0.1";
        nativeDataDir = "${m.private.gateway}/native-data";
        nativeDataOwner = m.roles.gateway.name;
        nativeDataGroup = m.roles.gateway.name;
        extraHosts."host.containers.internal" = "127.0.0.1";
        extraLitellmSettings = {
          callbacks = [ "atrium_admission.hook.admission" ];
          set_verbose = false;
          turn_off_message_logging = true;
        };
        extraEnvironment = {
          ATRIUM_ADMISSION_SETTINGS = m.admissionSettingsPath;
          LITELLM_WORKER_STARTUP_HOOKS = "atrium_admission.bootstrap:install";
          PYTHONPATH = "/opt/atrium-admission:/opt/atrium-resolver:/opt/atrium-profiles:/opt/atrium-certifi";
          PYTHONDONTWRITEBYTECODE = "1";
          LITELLM_TELEMETRY = "False";
          DO_NOT_TRACK = "1";
          HOME = m.private.gateway;
          TMPDIR = "${m.private.gateway}/scratch";
        };
      };
      modules.services.gatus.contributions.litellm.url =
        lib.mkForce "${runtime.endpoints.models}/health/liveliness";
      modules.services.homepage.contributions.litellm.siteMonitor =
        lib.mkForce "${runtime.endpoints.models}/health/liveliness";
      virtualisation.oci-containers.containers.litellm = {
        user = "${toString m.roles.gateway.uid}:${toString m.roles.gateway.gid}";
        volumes = lib.mkAfter [
          "${runtime.paths.policy}:${runtime.paths.policy}:ro"
          "${m.exports.resolver}:${m.exports.resolver}:ro"
          "${m.exports.controller}:${m.exports.controller}:ro"
          "${m.private.gateway}:${m.private.gateway}:rw"
          (packageMount packages.atrium-litellm-admission "/opt/atrium-admission")
          (packageMount packages.resolver "/opt/atrium-resolver")
          (packageMount packages.credential-profiles "/opt/atrium-profiles")
          (packageMount pkgs.python312Packages.certifi "/opt/atrium-certifi")
        ];
        extraOptions = lib.mkAfter [
          "--network=host"
          "--group-add=${toString m.metadataGroup.gid}"
          "--cap-drop=ALL"
          "--security-opt=no-new-privileges"
        ];
      };
      systemd.services = {
        atrium-resolver = {
          unitConfig.AssertFileNotEmpty = [
            "${m.private.resolver}/initialized"
            "${m.private.resolver}/admission-associations.json"
            "${m.private.resolver}/associations.json"
          ];
          restartTriggers = [ config.services.atrium.generated.litellm ];
          serviceConfig = {
            ReadWritePaths = [ m.exports.resolver ];
            ReadOnlyPaths = [ m.exports.controller ];
          };
        };
        atrium-reconciler = lib.recursiveUpdate (stateUnit m.roles.controller) {
          description = "Reconcile only new cc.* model objects with live producer publications";
          wantedBy = [ "multi-user.target" ];
          wants = [ "network-online.target" ];
          after = [ "zfs-service-datasets.service" "network-online.target" "firewall.service" "atrium-resolver.service" "podman-litellm.service" ];
          requires = [ "zfs-service-datasets.service" "firewall.service" "atrium-resolver.service" "podman-litellm.service" ];
          restartTriggers = [
            config.services.atrium.generated.litellm
            config.environment.etc."atrium/runtime/model-controller.json".source
          ];
          unitConfig.AssertFileNotEmpty = [
            "${m.private.controller}/ownership.json"
            "${runtime.paths.policy}/model-adoption.approved"
          ];
          serviceConfig = reconcilerProjection // {
            Type = "oneshot";
            SupplementaryGroups = [ m.metadataGroup.name m.deliveryGroup.name ];
            ReadWritePaths = [ m.private.controller m.exports.controller "/run/atrium-delivery/whiskey" ];
            ReadOnlyPaths = [ m.exports.resolver "-/run/atrium-acknowledgements/whiskey" ];
            ExecStartPre = reconcilerProjection.ExecStartPre ++ [
              "${bootstrapProgram} controller-publication --config ${controllerConfig} --confirm-existing-installation ${runtime.installation}"
            ];
            ExecStart = "${management} reconcile --config ${controllerConfig}"
              + lib.optionalString (!cfg.adoption.whiskeyText) " --no-rotate";
          };
        };
        podman-litellm = {
          requires = [ "firewall.service" "atrium-model-policy.service" "atrium-admission-settings.service" ];
          after = [ "firewall.service" "atrium-model-policy.service" "atrium-admission-settings.service" ];
          restartTriggers = [
            config.services.atrium.generated.resolver
            config.environment.etc."atrium/runtime/model-admission.json".source
          ];
          unitConfig = {
            RequiresMountsFor = [ m.private.gateway runtime.paths.policy ];
            AssertFileNotEmpty = [
              "${runtime.paths.policy}/model-adoption.approved"
              "${m.admission.runtime_directory}/initialized"
              "${m.admission.runtime_directory}/admission-state.json"
              "${m.private.controller}/ownership.json"
              "${m.private.resolver}/admission-associations.json"
            ];
          };
          serviceConfig = {
            StandardOutput = "null";
            StandardError = "null";
          };
        };
        atrium-model-health = lib.recursiveUpdate (stateUnit m.roles.gateway) {
          description = "Check live model publication freshness without reading service tokens";
          requires = [ "zfs-service-datasets.service" "atrium-admission-settings.service" ];
          after = [ "zfs-service-datasets.service" "atrium-admission-settings.service" ];
          script = ''
            set -eu
            now=$(${pkgs.coreutils}/bin/date +%s)
            for path in ${m.exports.resolver}/associations.json ${m.exports.controller}/native-bindings.json ${m.exports.controller}/service-associations.json; do
              timestamp=$(${pkgs.coreutils}/bin/stat -c %Y "$path")
              test "$timestamp" -le "$now"
              test "$((now - timestamp))" -le 80
            done
            ${admission} --settings ${m.admissionSettingsPath} status >/dev/null
          '';
          serviceConfig = {
            Type = "oneshot";
            PrivateNetwork = true;
            ReadWritePaths = [ "${m.private.gateway}/admission" ];
            StandardOutput = "null";
          };
        };
      };
      systemd.timers = {
        atrium-reconciler = {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnBootSec = "30s";
            OnUnitInactiveSec = "20s";
            AccuracySec = "1s";
            RandomizedDelaySec = "0";
            Unit = "atrium-reconciler.service";
          };
        };
        atrium-model-health = {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnBootSec = "2m";
            OnUnitInactiveSec = "20s";
            Unit = "atrium-model-health.service";
          };
        };
      };
      networking.firewall = {
        extraCommands = ''
          ${pkgs.iptables}/bin/iptables -C OUTPUT ${firewallRule} 2>/dev/null \
            || ${pkgs.iptables}/bin/iptables -I OUTPUT ${firewallRule}
        '';
        extraStopCommands = ''
          ${pkgs.iptables}/bin/iptables -D OUTPUT ${firewallRule} 2>/dev/null || true
        '';
      };
      modules.alerting.rules = {
        atrium-reconciler-failed =
          let alert = failedAlert "atrium-reconciler" "Atrium owned-model reconciliation needs attention"; in
          alert // {
            annotations = alert.annotations // {
              description = "Inspect the reconciler's error code. service_ack_timeout means a published model key is still unconfirmed. Whiskey validates replacements in the background without paid inference, so idle use alone should not cause this failure. Inspect Whiskey's handoff result, gateway connectivity and credential-file access. A valid acknowledgement lets the next timer run recover; retirement still requires acknowledgement and overlap, and native expiry applies. Never reset ownership/history, fabricate an acknowledgement, or add paid keepalive requests.";
              command = "journalctl -u atrium-reconciler.service -u whiskey-whiskey-whiskey.service -n 40 --no-pager";
              runbook_url = "https://github.com/carpenike/nix-config/blob/main/docs/services/atrium-whiskey-cutover.md#first-use-and-idle-rotation-alerts";
            };
          };
        atrium-model-health-failed = failedAlert "atrium-model-health" "Atrium model publication or admission history is unavailable";
      };
    })
  ];
}
