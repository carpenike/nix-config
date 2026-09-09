{ atrium, config, lib, pkgs, ... }:
let
  ids = import ../../../lib/service-uids.nix { };
  controllerIds = ids.atrium-reconciler-fixture;
  consumerIds = ids.atrium-consumer-fixture;
  fixture = import ../../../tests/atrium_n04/fixture.nix { inherit atrium; };
  package = atrium.packages.${pkgs.stdenv.hostPlatform.system}.atrium-litellm-controller;
  controllerConfig = pkgs.writeText "atrium-n04-isolated-controller.json" (builtins.toJSON {
    schema_version = 1;
    environment = "isolated";
    installation = "atrium-n04-fixture";
    issuer = "https://litellm.atrium.invalid";
    endpoint = "http://127.0.0.1:14004";
    desired_state = "/etc/atrium/desired-state/litellm.json";
    ownership_directory = "/var/lib/atrium-reconciler";
    association_snapshot = "/run/atrium-n04-input/associations.json";
    association_publisher_uid = 0;
    service_association_snapshot = "/var/lib/atrium-reconciler/service-associations.json";
    bindings_snapshot = "/var/lib/atrium-reconciler/native-bindings.json";
    management_key_file = "/run/credentials/atrium-reconciler.service/management";
    backend_transports = lib.mapAttrs (_: _: { api_base = "http://models.atrium.invalid:8000/v1"; })
      fixture.sourceRegistry.modelBackends;
    service_delivery.whiskey-service = {
      ack_path = "/run/atrium-n04/acks/key.json";
      consumer_uid = consumerIds.uid;
      consumer_gid = consumerIds.gid;
      ack_timeout_seconds = 60;
    };
  });
in
{
  imports = [ atrium.nixosModules.atrium ];
  assertions = [{
    assertion = config.networking.hostName == "atrium-n04-fixture";
    message = "ATR-N04 controller wiring is isolated-fixture only; never import it into live Forge.";
  }];

  services.atrium = {
    enable = true;
    registry = fixture.sourceRegistry;
    runtime = {
      reconciler = {
        enable = true;
        inherit package;
        executable = "atrium-litellm-controller";
        arguments = [ "reconcile" "--config" (toString controllerConfig) ];
        credentials.management = "/run/atrium-n04-input/management";
      };
      reconcileSchedule = "*-*-* *:*:*";
    };
  };

  users.groups.atrium-reconciler.gid = controllerIds.gid;
  users.groups.atrium-consumer-fixture.gid = consumerIds.gid;
  users.users.atrium-reconciler = {
    isSystemUser = true;
    uid = controllerIds.uid;
    group = "atrium-reconciler";
    inherit (controllerIds) extraGroups;
  };
  users.users.atrium-consumer-fixture = {
    isSystemUser = true;
    uid = consumerIds.uid;
    group = "atrium-consumer-fixture";
    inherit (consumerIds) extraGroups;
  };

  # Provision references only. Issuance and secret material stay in the isolated runtime.
  systemd.tmpfiles.rules = [
    "d /run/atrium-n04 0755 root root -"
    "d /run/atrium-n04/delivery 0750 atrium-reconciler atrium-consumer-fixture -"
    "d /run/atrium-n04/acks 0750 atrium-consumer-fixture atrium-consumer-fixture -"
    "d /run/atrium-n04-input 0750 root atrium-reconciler -"
  ];
  systemd.services.atrium-reconciler = {
    restartTriggers = [ controllerConfig ];
    serviceConfig = {
      DynamicUser = lib.mkForce false;
      ReadWritePaths = [ "/var/lib/atrium-reconciler" "/run/atrium-n04/delivery" ];
      ReadOnlyPaths = [ "/run/atrium-n04-input/associations.json" "/run/atrium-n04/acks" ];
      IPAddressDeny = "any";
      IPAddressAllow = [ "localhost" ];
      ProtectProc = "invisible";
      ProcSubset = "pid";
      MemoryMax = "256M";
      TimeoutStartSec = "120s";
    };
  };
  systemd.timers.atrium-reconciler.timerConfig = {
    AccuracySec = "1s";
    RandomizedDelaySec = "0";
  };
  environment.etc."atrium/n04-controller.json".source = controllerConfig;
}
