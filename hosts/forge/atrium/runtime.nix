{ lib
, policyPath ? "/etc/atrium/desired-state/resolver.json"
, adoption ? { models = false; native = false; whiskey = false; whiskeyText = false; }
, modelSettings ? null
, groupEvidence ? null
, browserOrigin ? null
}:
let
  identity = import ./identity.nix { inherit lib; };
  projection = import ./credential-projection.nix { inherit lib; };
  runtimeIdentitySettings = identity.settings // {
    authorities = map
      (authority: authority // lib.optionalAttrs
        (groupEvidence != null && authority.id == identity.authority.id)
        {
          group_evidence = {
            client_ids = groupEvidence.clientIds;
            max_token_lifetime_seconds = groupEvidence.maxTokenLifetimeSeconds;
          };
        })
      identity.settings.authorities;
  };
  paths = {
    resolver = identity.settings.state_directory;
    trust = "/var/lib/atrium-trust";
    policy = "/var/lib/atrium-policy";
  };
  endpoints = {
    resolver = "https://atrium.holthome.net";
    registration = "https://forge.holthome.net:19443";
    native = "https://mcp.holthome.net";
    nativeIssue = "https://mcp.holthome.net/cc/issue";
    nativeIssueTransport = "https://127.0.0.1:9200/cc/issue";
    nativePolicy = "https://127.0.0.1:18767/v1/native-policy";
    whiskey = "https://whiskeywhiskeywhiskey.org";
    models = "https://llm.holthome.net";
  };
  ports = {
    resolver = 18765;
    registration = 18766;
    registrationEntry = 19443;
    nativePolicy = 18767;
    whiskeyMetrics = 13417;
  };
  credential = projection.path;
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
  brokerCredentials = {
    native-ca = "${paths.trust}/native-ca.crt.pem";
    native-client-cert = "${paths.trust}/resolver-client.crt.pem";
    native-client-key = "${paths.trust}/resolver-client.key.pem";
    native-jwks = "${paths.policy}/native-jwks.json";
  };
  policyCredentials = {
    policy-server-cert = "${paths.trust}/policy-server.crt.pem";
    policy-server-key = "${paths.trust}/policy-server.key.pem";
    policy-client-ca = "${paths.trust}/policy-client-ca.crt.pem";
    policy-client-cert = "${paths.trust}/policy-client.crt.pem";
  };
  nativeCredentials = {
    server-cert = "${paths.trust}/native-server.crt.pem";
    server-key = "${paths.trust}/native-server.key.pem";
    resolver-client-ca = "${paths.trust}/issuer-ca.crt.pem";
    resolver-client-cert = "${paths.trust}/resolver-client.crt.pem";
    resolver-jwks = "${paths.policy}/resolver-jwks.json";
    native-profile = "${paths.policy}/native-profile.json";
    public-ca = "/etc/ssl/certs/ca-certificates.crt";
    policy-ca = "${paths.trust}/policy-ca.crt.pem";
    policy-client-cert = "${paths.trust}/policy-client.crt.pem";
    policy-client-key = "${paths.trust}/policy-client.key.pem";
  };
  resolverConfig = unit: runtimeIdentitySettings // {
    policy_path = policyPath;
    group_authority = identity.authority.id;
    inherit signing;
    devices = {
      ca_certificate_path = projection.path unit "device-ca";
      ca_private_key_path = projection.path unit "device-ca-key";
      server_certificate_path = projection.path unit "registration-cert";
      server_private_key_path = projection.path unit "registration-key";
      certificate_lifetime_seconds = 86400;
      max_challenges_per_principal = 32;
    };
    home_mcp = if unit != "atrium-resolver" || !adoption.native then null else {
      deployments.home-mcp = {
        endpoint = endpoints.nativeIssue;
        transport_endpoint = endpoints.nativeIssueTransport;
        ca_certificate_path = projection.path unit "native-ca";
        client_certificate_path = projection.path unit "native-client-cert";
        client_private_key_path = projection.path unit "native-client-key";
        verification_keys_path = projection.path unit "native-jwks";
        timeout_seconds = 5;
      };
    };
    litellm = if unit == "atrium-resolver" && adoption.models then modelSettings else null;
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
  inherit identity paths endpoints ports deviceCredentials brokerCredentials policyCredentials nativeCredentials;
  registrationAddress = "10.20.0.30";
  registrationInterface = "enp8s0";
  installation = "atrium-forge";
  bootstrap = runtimeIdentitySettings // {
    inherit signing;
    policy_path = policyPath;
    group_authority = identity.authority.id;
  };
  resolver = resolverConfig "atrium-resolver";
  registration = resolverConfig "atrium-device-registration";
  nativePolicyTemplate = (resolverConfig "atrium-native-policy") // {
    devices = null;
    native_policy = {
      audience = endpoints.nativePolicy;
      server_certificate_path = credential "atrium-native-policy" "policy-server-cert";
      server_private_key_path = credential "atrium-native-policy" "policy-server-key";
      client_ca_path = credential "atrium-native-policy" "policy-client-ca";
      adapters = [{
        id = "homelab-mcp";
        native_issuer = endpoints.native;
        deployment = "home-mcp";
        authorities.${identity.authority.id} = "mcp";
        views = [
          "personal-data-read"
          "family-home-read"
          "personal-finance"
          "personal-scribe"
          "personal-status"
          "personal-money"
        ];
        # Replaced by the actual nominated public leaf's fingerprint at runtime.
        certificates = [ ];
      }];
    };
  };
  native = {
    profile_path = credential "homelab-mcp" "native-profile";
    resource = {
      id = "personal-data-read";
      domain = "personal:ryan";
      audience = "home-mcp";
      target = "${endpoints.native}/mcp";
    };
    issuance = {
      resolver_issuer = endpoints.resolver;
      resolver_jwks = credential "homelab-mcp" "resolver-jwks";
      policy_path = policyPath;
      tls = {
        server_certificate = credential "homelab-mcp" "server-cert";
        server_private_key = credential "homelab-mcp" "server-key";
        client_ca = credential "homelab-mcp" "resolver-client-ca";
        resolver_certificates = [ ];
      };
    };
    policy = {
      endpoint = endpoints.nativePolicy;
      authority = identity.authority.id;
      resolver_issuer = endpoints.resolver;
      resolver_jwks = credential "homelab-mcp" "resolver-jwks";
      ca_certificate_path = credential "homelab-mcp" "policy-ca";
      client_certificate_path = credential "homelab-mcp" "policy-client-cert";
      client_private_key_path = credential "homelab-mcp" "policy-client-key";
      timeout_seconds = 5;
    };
    deny = {
      issuer = endpoints.resolver;
      feed_url = "${endpoints.resolver}/v1/deny-feed";
      jwks_url = "${endpoints.resolver}/.well-known/jwks.json";
      ca_bundle = credential "homelab-mcp" "public-ca";
      state_directory = "/var/lib/homelab-mcp/denial";
    };
  };
  whiskey = lib.optionalAttrs (browserOrigin != null)
    {
      browser_origin = browserOrigin;
    } // {
    schema_version = 1;
    issuer = endpoints.resolver;
    jwks_uri = "${endpoints.resolver}/.well-known/jwks.json";
    native_issuer = identity.authority.issuer;
    authority = identity.authority.id;
    domain = "personal:ryan";
    instance_id = "personal-whiskey";
    target = "${endpoints.whiskey}/cc/mcp";
    isolated_harness = false;
    deny = {
      feed_uri = "${endpoints.resolver}/v1/deny-feed";
      state_directory = "${paths.policy}/whiskey-admission";
    };
  };
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
      group_evidence = {
        status = if groupEvidence == null then "accepted-unconfigured" else "configured-awaiting-operator-adoption";
        amendment = { pr = 42; acceptance_revision = "e8e4d54"; accepted = true; };
        dependency = "Explicit operator-declared admitted public OAuth clients and operator provisioning/adoption; qualification fixtures do not supply production admission.";
        configured = groupEvidence != null;
        admitted_client_ids = if groupEvidence == null then [ ] else groupEvidence.clientIds;
        max_token_lifetime_seconds = if groupEvidence == null then null else groupEvidence.maxTokenLifetimeSeconds;
        admission_path = "/v1/group-evidence";
        resource_authentication = "access-token-bearer-only";
        additional_carrier = "paired-signed-id-token-in-explicit-protected-body";
        live_client_provisioning_performed = false;
        native_c10_qualification_executed_here = false;
        supplied_qualification = {
          status = "receipt-provided-parent-review";
          network_pr = 38;
          report_revision = "51156b7a11b5e923414df5da31897c7843efeac8";
          execution_revision = "a2c99ed8f05b647b8566853757889d3e1a0bbb17";
          core_revision = "ca621d753529b3ba89e67fef6f3c3f80aade332d";
          checks = 53;
          evidence_layers = [ "actual-pocket-id-2.14-and-helper" "real-crypto-signed-synthetic-adverse-cases" ];
          executed_by_this_deployment = false;
          proves_live_client_admission = false;
        };
        coordinated_native = {
          report_revision = "a1d7322bc600df04ecc928cf2692ea71fb2b9fac";
          execution_revision = "c79bf79b6e712f683e72c710402cd69457737c12";
          vendor_revision = "ca621d753529b3ba89e67fef6f3c3f80aade332d";
          parent_reported_cases = 625;
          c10_cases_included = 20;
          executed_by_this_deployment = false;
          production_activation = false;
        };
        provider_version = "Pocket ID 2.14";
        resource_access_jwt_contains_groups = false;
        signed_id_token_contains_groups = true;
        signed_id_token_has_access_token_hash_binding = true;
        userinfo_has_signed_source_lifetime = false;
        missing_groups = "deny";
        principal_acl_fallback = false;
        unsigned_userinfo_fallback = false;
        identity_carrier_change = false;
        provenance = {
          reported_by = "parent";
          network_pr = 37;
          network_revision = "4ed8810";
          native_measurement_source = "f17c887";
          completed_measurements = 11;
          expected_blocked_exit_status = 2;
          cleanup_complete = true;
          reproduced_by_this_deployment = false;
        };
      };
    };
    home_mcp = {
      enabled = adoption.native;
      issuer = endpoints.native;
      upstream_client_id = "mcp";
      issuance_endpoint = endpoints.nativeIssue;
      issuance_transport_endpoint = endpoints.nativeIssueTransport;
      policy_endpoint = endpoints.nativePolicy;
      requirements = [
        "Final C9-compatible native vendor and real adapter qualification; a read-catalog build alone is not adoption evidence."
        "Explicit native issuer signing-key continuity and public JWKS export."
        "Explicit legacy-identity/refresh-family mappings and retained history."
        "Pinned source-defined atrium-personal-read and atrium-family-read catalogs; writable legacy scopes are not wing views."
        "Owner-selected current grants; no email matching or automatic group grants."
        "Separate manual finance-client grants; ordinary read-only grants are not widened."
        "Exact-resource OAuth for finance/scribe/status; fresh client sign-in without deleting old token caches or refresh history."
        "Scribe/status use explicit Ryan principal grants; group removal alone does not revoke those automation grants."
        "Explicit admitted public OAuth clients for accepted C10; no service-client or resource-audience inference."
        "Explicit public /mcp read-only cutover and individually selected refresh grants; no implicit legacy-client adoption."
        "Preserved native deny history and operator adoption receipt."
      ];
    };
    models = {
      enabled = adoption.models;
      endpoint = endpoints.models;
      native_version = "v1.100.1";
      image = "ghcr.io/berriai/litellm:v1.100.3@sha256:a68b34df312f1e72914f0886384517fa4fdb09013480460b80a4e3a40104376b";
      requirements = [
        "Provision distinct new Personal and Family inference credentials through SOPS and the declared runtime references."
        "Account labels are new Atrium purpose/ownership declarations, not discovered provider billing identities."
        "Provision separate controller/resolver management credentials; never reuse inference credentials or silently adopt the gateway master key."
        "Explicitly initialize real resolver/controller/admission history and preserve existing unowned gateway objects."
        "Live resolver/controller publications under distinct producer UIDs; metadata and service tokens stay separate."
      ];
    };
    whiskey = {
      enabled = adoption.whiskey;
      text_enabled = adoption.whiskeyText;
      endpoint = endpoints.whiskey;
      native_resource = "${endpoints.whiskey}/api/mcp";
      requirements = [
        "Explicit route and text adoption receipts; preserve native, session, PAT and issuer history."
        "Provision the declared Personal image credentials and review exact non-model egress addresses, including calendar/media/push redirects."
        "Use the cc.personal.ryan.whiskey-service template and live key/acknowledgement paths; no environment token snapshot."
        "Native credential plus matching companion on /cc/mcp; native/PAT/session routes unchanged."
      ];
    };
  };
}
