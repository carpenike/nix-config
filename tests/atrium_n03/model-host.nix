{ inputs, config, lib, pkgs, ... }:
let
  f = import ./fixture.nix {
    inherit inputs;
    enableModels = config.services.atriumN03Models.enable;
  };
  m = f.models;
  jsonFile = name: value: pkgs.writeText name (builtins.toJSON value);
  controllerPackage = pkgs.callPackage ../../pkgs/atrium-litellm-controller { };
  resolverPackage = inputs.atrium.packages.${pkgs.system}.resolver;
  profilesPackage = inputs.atrium.packages.${pkgs.system}.credential-profiles;
  admissionPackage = pkgs.callPackage ../../pkgs/atrium-litellm-admission/package.nix {
    python3Packages = pkgs.python312Packages;
    atriumResolver = resolverPackage;
    atriumProfiles = profilesPackage;
  };
  controllerConfig = jsonFile "atrium-n03-model-controller.json" m.controller;
  admissionConfig = jsonFile "atrium-n03-model-admission.json" m.admission;
  gatewayConfig = jsonFile "atrium-n03-model-gateway.json" m.gateway;
  policy = jsonFile "atrium-n03-model-policy.json" f.generated.resolver;
  resolverCandidate = jsonFile "atrium-n03-model-resolver.json"
    (f.resolver // { litellm = m.resolver; });
  packageMount = package: destination:
    "${package}/${pkgs.python312.sitePackages}:${destination}:ro";
  nativeEnvironment = m.gatewayEnvironment // {
    PYTHONPATH = "/opt/atrium-admission:/opt/atrium-resolver:/opt/atrium-profiles:/opt/atrium-certifi";
  };
in
{
  imports = [ ../atrium_n05/module.nix ];
  options.services.atriumN03Models.enable = lib.mkEnableOption "explicitly opted-in isolated N03 model assembly";
  config = {
    assertions = [
      {
        assertion = !f.modelPlaneReady || m.acceptedPublisherPins.verified;
        message = "N03 model activation requires verified accepted publisher sources and proof anchors.";
      }
      {
        assertion = lib.unique (map (role: role.uid) (builtins.attrValues m.roles))
          == map (role: role.uid) (builtins.attrValues m.roles)
          && m.metadataGroup.gid != m.deliveryGroup.gid;
        message = "N03 model publishers/consumers require distinct fixture UIDs and separate metadata/token groups.";
      }
    ];

    services.atriumLitellmAdmission = {
      enable = f.modelPlaneReady;
      isolatedHarness = true;
      package = admissionPackage;
      settingsFile = m.admissionSettingsPath;
    };
    services.atrium.runtime = {
      reconciler = {
        enable = f.modelPlaneReady;
        package = controllerPackage;
        executable = "atrium-litellm-controller";
        arguments = [ "reconcile" "--config" (toString controllerConfig) ];
        credentials.management = "${f.runtime}-input/controller-model-management";
      };
      reconcileSchedule = "*-*-* *:*:*";
    } // lib.optionalAttrs f.modelPlaneReady {
      resolver = {
        arguments = lib.mkForce [ "--config" (toString resolverCandidate) "serve" "--port" "18765" ];
        credentials.model-management = "${f.runtime}-input/resolver-model-management";
      };
    };

    users.groups = {
      ${m.metadataGroup.name}.gid = m.metadataGroup.gid;
      ${m.roles.controller.name}.gid = m.roles.controller.gid;
      ${m.roles.gateway.name}.gid = m.roles.gateway.gid;
    };
    users.users = {
      ${m.roles.resolver.name}.extraGroups = [ m.metadataGroup.name ];
      ${m.roles.controller.name} = {
        isSystemUser = true;
        uid = m.roles.controller.uid;
        group = m.roles.controller.name;
        extraGroups = [ m.metadataGroup.name m.deliveryGroup.name ];
      };
      ${m.roles.gateway.name} = {
        isSystemUser = true;
        uid = m.roles.gateway.uid;
        group = m.roles.gateway.name;
        extraGroups = [ m.metadataGroup.name ];
      };
    };

    systemd.tmpfiles.rules = [
      "d /run/atrium-n03-publications 0755 root root -"
      "d ${f.runtime}/model-inputs 0750 root ${m.metadataGroup.name} -"
      "d ${f.runtime}/provider-input 0700 ${m.roles.controller.name} ${m.roles.controller.name} -"
      "d ${m.private.resolver} 0700 ${m.roles.resolver.name} ${m.roles.resolver.name} -"
      "d ${m.private.controller} 0700 ${m.roles.controller.name} ${m.roles.controller.name} -"
      "d ${m.private.gateway} 0700 ${m.roles.gateway.name} ${m.roles.gateway.name} -"
      "d ${m.private.gateway}/config 0700 ${m.roles.gateway.name} ${m.roles.gateway.name} -"
      "d ${m.private.gateway}/scratch 0700 ${m.roles.gateway.name} ${m.roles.gateway.name} -"
      "d ${m.admission.runtime_directory} 0700 ${m.roles.gateway.name} ${m.roles.gateway.name} -"
      "d ${f.runtime}/delivery 2750 ${m.roles.controller.name} ${m.deliveryGroup.name} -"
      "d ${f.runtime}/acknowledgements 0755 root root -"
      "d ${f.runtime}/acknowledgements/whiskey 0750 ${m.roles.whiskey.name} ${m.deliveryGroup.name} -"
    ] ++ map
      (directory: "d ${directory.path} ${directory.mode} ${directory.owner} ${directory.group} -")
      m.publisherDirectories;

    # Static configuration contains references only; private runtime inputs remain external.
    environment.etc = {
      "atrium/n03/model-preparation.json".source = jsonFile "atrium-n03-model-preparation.json" m;
      "atrium/n03/model-controller.json".source = controllerConfig;
      "atrium/n03/model-gateway.json".source = gatewayConfig;
      "atrium/n03/model-resolver-candidate.json".source = resolverCandidate;
    };
    systemd.services = {
      atrium-n03-model-inputs = {
        enable = f.modelPlaneReady;
        description = "Install only root-owned static model policy and public CA";
        script = ''
          set -eu
          ${pkgs.coreutils}/bin/install -m ${m.inputFileMode} -g ${m.metadataGroup.name} ${policy} ${m.policyPath}
          ${pkgs.coreutils}/bin/install -m ${m.inputFileMode} -g ${m.metadataGroup.name} ${f.runtime}-input/front-ca ${f.runtime}/model-inputs/front-ca
        '';
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          User = "root";
          SupplementaryGroups = [ m.metadataGroup.name ];
          NoNewPrivileges = true;
          CapabilityBoundingSet = [ "" ];
          AmbientCapabilities = [ "" ];
        };
      };
      atrium-n03-admission-settings = {
        enable = f.modelPlaneReady;
        description = "Deliver static admission settings as their actual gateway reader";
        script = ''
          set -eu
          ${pkgs.coreutils}/bin/install -m ${m.admissionSettingsFileMode} ${admissionConfig} ${m.admissionSettingsPath}
        '';
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          User = m.roles.gateway.name;
          Group = m.roles.gateway.name;
          UMask = "0077";
          NoNewPrivileges = true;
          CapabilityBoundingSet = [ "" ];
          AmbientCapabilities = [ "" ];
        };
      };
      atrium-resolver.serviceConfig = lib.mkIf f.modelPlaneReady {
        ReadWritePaths = [ m.private.resolver m.exports.resolver ];
        ReadOnlyPaths = [ m.exports.controller ];
      };
      atrium-reconciler = {
        enable = f.modelPlaneReady;
        requires = [ "atrium-n03-network.service" "podman-atrium-n03-models.service" ];
        after = [ "atrium-n03-network.service" "podman-atrium-n03-models.service" ];
        restartTriggers = [ controllerConfig ];
        serviceConfig = {
          DynamicUser = lib.mkForce false;
          User = m.roles.controller.name;
          Group = m.roles.controller.name;
          SupplementaryGroups = [ m.metadataGroup.name m.deliveryGroup.name ];
          NetworkNamespacePath = f.namespacePath;
          NoNewPrivileges = true;
          CapabilityBoundingSet = lib.mkForce [ "" ];
          AmbientCapabilities = lib.mkForce [ "" ];
          StateDirectory = "atrium-reconciler";
          StateDirectoryMode = "0700";
          UMask = "0077";
          ReadWritePaths = [ m.private.controller m.exports.controller "${f.runtime}/delivery" ];
          ReadOnlyPaths = [ m.exports.resolver "${f.runtime}/acknowledgements/whiskey" "${f.runtime}/provider-input" ];
          ProtectSystem = "strict";
          ProtectHome = true;
          ProtectProc = "invisible";
        };
      };
      podman-atrium-n03-models = {
        enable = f.modelPlaneReady;
        requires = [ "atrium-n03-network.service" "atrium-n03-model-inputs.service" "atrium-n03-admission-settings.service" ];
        after = [ "atrium-n03-network.service" "atrium-n03-model-inputs.service" "atrium-n03-admission-settings.service" ];
        unitConfig.ConditionPathExists = "${m.admission.runtime_directory}/initialized";
        serviceConfig = {
          StandardOutput = "null";
          StandardError = "null";
        };
      };
    };
    systemd.timers.atrium-reconciler = {
      enable = f.modelPlaneReady;
      timerConfig = { AccuracySec = "1s"; RandomizedDelaySec = "0"; };
    };

    # The launcher owns container setup; the actual gateway has its own UID, only
    # metadata membership, no capabilities, and no publisher-private mounts.
    virtualisation.oci-containers = {
      backend = "podman";
      containers.atrium-n03-models = {
        image = f.versions.litellm;
        autoStart = f.modelPlaneReady;
        user = "${toString m.roles.gateway.uid}:${toString m.roles.gateway.gid}";
        entrypoint = "/app/docker/prod_entrypoint.sh";
        workdir = m.gatewayWorkingDirectory;
        cmd = m.gatewayCommand;
        environment = nativeEnvironment;
        environmentFiles = [ "${f.runtime}-input/gateway-secrets.env" ];
        volumes = [
          "${gatewayConfig}:/etc/atrium/n03/model-gateway.json:ro"
          "${f.runtime}/model-inputs:${f.runtime}/model-inputs:ro"
          "${m.exports.resolver}:${m.exports.resolver}:ro"
          "${m.exports.controller}:${m.exports.controller}:ro"
          "${m.private.gateway}:${m.private.gateway}:rw"
          (packageMount admissionPackage "/opt/atrium-admission")
          (packageMount resolverPackage "/opt/atrium-resolver")
          (packageMount profilesPackage "/opt/atrium-profiles")
          (packageMount pkgs.python312Packages.certifi "/opt/atrium-certifi")
        ];
        extraOptions = [
          "--network=ns:${f.namespacePath}"
          "--group-add=${toString m.metadataGroup.gid}"
          "--cap-drop=ALL"
          "--security-opt=no-new-privileges"
          "--pull=never"
          "--log-driver=none"
          "--memory=3072m"
          "--cpus=2"
          "--pids-limit=256"
        ] ++ lib.mapAttrsToList
          (_: name: "--add-host=${name}:${f.frontAddress}")
          (lib.filterAttrs (name: _: name != "native") f.names);
      };
    };
  };
}
