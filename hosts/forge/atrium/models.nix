{ lib, ids, runtime, registry }:
let
  projection = import ./credential-projection.nix { inherit lib; };
  roles = {
    resolver = { name = "atrium-resolver"; inherit (ids.atrium-resolver) uid gid; };
    controller = { name = "atrium-reconciler"; inherit (ids.atrium-reconciler) uid gid; };
    gateway = { name = "atrium-model-gateway"; inherit (ids.atrium-model-gateway) uid gid; };
    whiskey = { name = "whiskey-whiskey-whiskey"; inherit (ids.atrium-whiskey) uid gid; };
  };
  metadataGroup = { name = "atrium-model-metadata"; inherit (ids.atrium-model-metadata) gid; };
  deliveryGroup = { name = "atrium-whiskey-delivery"; inherit (ids.atrium-whiskey-delivery) gid; };
  exports = {
    resolver = "/run/atrium-publications/resolver";
    controller = "/run/atrium-publications/controller";
  };
  private = {
    resolver = "${runtime.paths.resolver}/models";
    controller = "/var/lib/atrium-reconciler";
    gateway = "/var/lib/atrium-model-gateway";
  };
  acknowledgementPath = "/run/atrium-acknowledgements/whiskey/key.json";
  controllerFor = unit: {
    schema_version = 1;
    environment = "production";
    inherit (runtime) installation;
    issuer = runtime.endpoints.models;
    endpoint = runtime.endpoints.models;
    desired_state = "/etc/atrium/desired-state/litellm.json";
    ownership_directory = private.controller;
    association_snapshot = "${exports.resolver}/associations.json";
    association_publisher_uid = roles.resolver.uid;
    publication_reader_gid = metadataGroup.gid;
    bindings_snapshot = "${exports.controller}/native-bindings.json";
    service_association_snapshot = "${exports.controller}/service-associations.json";
    management_key_file = projection.path unit "management";
    backend_transports = lib.mapAttrs (_: _: { api_base = "https://api.anthropic.com"; })
      registry.modelBackends;
    service_delivery."cc.personal.ryan.whiskey-service" = {
      ack_path = acknowledgementPath;
      consumer_uid = roles.whiskey.uid;
      consumer_gid = deliveryGroup.gid;
      ack_timeout_seconds = 60;
    };
  };
in
{
  inherit roles metadataGroup deliveryGroup exports private acknowledgementPath controllerFor;
  policyPath = "/var/lib/atrium-policy/model-policy.json";
  admissionSettingsPath = "${private.gateway}/config/admission.json";
  resolver = {
    endpoint = runtime.endpoints.models;
    native_version = "v1.100.1";
    inherit (runtime) installation;
    runtime_directory = private.resolver;
    controller_key_file = projection.path "atrium-resolver" "model-management";
    controller_inventory_file = "${exports.controller}/native-bindings.json";
    controller_desired_state_path = "/etc/atrium/desired-state/litellm.json";
    controller_publisher_uid = roles.controller.uid;
    publication_directory = exports.resolver;
    publication_reader_gid = metadataGroup.gid;
    maintenance_interval_seconds = 20;
  };
  controller = controllerFor "atrium-reconciler";
  controllerCredentials = {
    management = "/run/secrets/atrium-litellm-controller-management";
    personal-anthropic = "/run/secrets/atrium-personal-anthropic";
    family-anthropic = "/run/secrets/atrium-family-anthropic";
  };
  resolverCredentials.model-management = "/run/secrets/atrium-litellm-resolver-management";
  admission = {
    schema_version = 1;
    isolated = false;
    environment = "production";
    native_version = "v1.100.1";
    inherit (runtime) installation;
    issuer = runtime.endpoints.models;
    runtime_directory = "${private.gateway}/admission";
    policy_path = "/var/lib/atrium-policy/model-policy.json";
    policy_publisher_uid = 0;
    producers = [
      {
        id = "resolver";
        kind = "resolver";
        path = "${exports.resolver}/admission-associations.json";
        publisher_uid = roles.resolver.uid;
      }
      {
        id = "controller-services";
        kind = "controller-service";
        path = "${exports.controller}/service-associations.json";
        publisher_uid = roles.controller.uid;
      }
    ];
    deny_issuer = runtime.endpoints.resolver;
    deny_url = "${runtime.endpoints.resolver}/v1/deny-feed";
    jwks_url = "${runtime.endpoints.resolver}/.well-known/jwks.json";
    poll_seconds = 20;
    fetch_timeout_seconds = 5;
  };
  whiskey = {
    schema_version = 1;
    inherit (runtime) installation;
    issuer = runtime.endpoints.models;
    model = "cc.personal.ryan.sonnet";
    template_id = "cc.personal.ryan.whiskey-service";
    key_path = registry.modelTemplates."cc.personal.ryan.whiskey-service".service.runtimeKeyPath;
    key_owner_uid = roles.controller.uid;
    acknowledgement_path = acknowledgementPath;
    isolated_harness = false;
  };
}
