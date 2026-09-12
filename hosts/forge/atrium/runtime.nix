{ lib, policyPath ? "/var/lib/atrium-policy/resolver.json" }:
let
  identity = import ./identity.nix { inherit lib; };
  paths = {
    resolver = identity.settings.state_directory;
    trust = "/var/lib/atrium-trust";
    policy = "/var/lib/atrium-policy";
  };
  endpoints = {
    resolver = "https://atrium.holthome.net";
    registration = "https://forge.holthome.net:19443";
    native = "https://mcp.holthome.net";
    nativeIssue = "https://127.0.0.1:9200/cc/issue";
    nativePolicy = "https://127.0.0.1:18767/v1/native-policy";
    whiskey = "https://whiskeywhiskeywhiskey.org";
    models = "https://llm.holthome.net";
  };
  ports = {
    resolver = 18765;
    registration = 18766;
    registrationEntry = 19443;
    nativePolicy = 18767;
  };
  credential = unit: name: "/run/credentials/${unit}.service/${name}";
  signing = {
    directory = "${paths.resolver}/signing";
    issuer = endpoints.resolver;
  };
  deviceCredentials = {
    device-ca = "${paths.trust}/device-ca.crt.pem";
    device-ca-key = "${paths.trust}/device-ca.key.pem";
    registration-cert = "${paths.trust}/registration-server.crt.pem";
    registration-key = "${paths.trust}/registration-server.key.pem";
  };
  resolverConfig = unit: identity.settings // {
    policy_path = policyPath;
    group_authority = identity.authority.id;
    inherit signing;
    devices = {
      ca_certificate_path = credential unit "device-ca";
      ca_private_key_path = credential unit "device-ca-key";
      server_certificate_path = credential unit "registration-cert";
      server_private_key_path = credential unit "registration-key";
      certificate_lifetime_seconds = 86400;
      max_challenges_per_principal = 32;
    };
    home_mcp = null;
    litellm = null;
    native_policy = null;
  };
  authority = id: common_name: {
    inherit id common_name;
    lifetime_seconds = 5 * 365 * 86400;
  };
  certificate = id: authority: common_name: purpose: names: {
    inherit id authority common_name purpose names;
    lifetime_seconds = 365 * 86400;
  };
in
{
  inherit identity paths endpoints ports deviceCredentials;
  registrationAddress = "10.20.0.30";
  registrationInterface = "enp8s0";
  installation = "atrium-forge";
  bootstrap = identity.settings // { inherit signing; };
  resolver = resolverConfig "atrium-resolver";
  registration = resolverConfig "atrium-device-registration";
  tlsPlan = {
    schema_version = 1;
    directory = paths.trust;
    authorities = [
      (authority "device-ca" "Atrium Forge enrolled devices")
      (authority "registration-ca" "Atrium Forge registration server")
      (authority "native-ca" "Atrium Forge Home MCP server")
      (authority "issuer-ca" "Atrium Forge resolver issuance client")
      (authority "policy-ca" "Atrium Forge native policy server")
      (authority "policy-client-ca" "Atrium Forge native policy client")
    ];
    certificates = [
      (certificate "registration-server" "registration-ca" "Atrium Forge registration" "server"
        [ "forge.holthome.net" "127.0.0.1" ])
      (certificate "native-server" "native-ca" "Atrium Forge Home MCP" "server"
        [ "mcp.holthome.net" "127.0.0.1" ])
      (certificate "resolver-client" "issuer-ca" "Atrium Forge resolver issuer" "client" [ ])
      (certificate "policy-server" "policy-ca" "Atrium Forge native policy" "server" [ "127.0.0.1" ])
      (certificate "policy-client" "policy-client-ca" "Atrium Forge Home MCP policy client" "client" [ ])
    ];
  };
  adoption = {
    schema_version = 1;
    environment = "production";
    identity = {
      issuer = identity.authority.issuer;
      audience = identity.authority.audience;
      enrollment_path = "/etc/atrium/bootstrap/identity.json";
      initialized_by_build = false;
    };
    home_mcp = {
      enabled = false;
      issuer = endpoints.native;
      upstream_client_id = "mcp";
      issuance_endpoint = endpoints.nativeIssue;
      policy_endpoint = endpoints.nativePolicy;
      requirements = [
        "Explicit native issuer signing-key continuity and public JWKS export."
        "Explicit legacy-identity/refresh-family mappings and retained history."
        "Owner-selected current grants; no email matching or automatic group grants."
        "Reviewed complete N02 policy and initialized native deny history."
      ];
    };
    models = {
      enabled = false;
      endpoint = endpoints.models;
      native_version = "v1.100.1";
      image = "ghcr.io/berriai/litellm:v1.100.1@sha256:a3715fa7ad8387941ab697259bd2881d68931657247a41984f90fae6d11c62bf";
      requirements = [
        "Explicit personal/family provider account and domain credential ownership."
        "Approved exact model aliases/backends, budgets and designated family model."
        "Separate new controller/resolver management credentials and cc.* ownership initialization."
        "Live signed resolver/controller publications with distinct producer custody."
      ];
    };
    whiskey = {
      enabled = false;
      endpoint = endpoints.whiskey;
      native_resource = "${endpoints.whiskey}/api/mcp";
      requirements = [
        "Explicit adopted LiteLLM text service template and live key/acknowledgement paths."
        "Domain-owned image-provider credentials and reviewed non-model egress destinations."
        "Native credential plus matching companion on /cc/mcp; native/PAT/session routes unchanged."
      ];
    };
  };
}
