{ inputs, config, lib, pkgs, ... }:
let
  f = import ./fixture.nix {
    inherit inputs;
    enableModels = config.services.atriumN03Models.enable;
  };
  resolverPackage = inputs.atrium.packages.${pkgs.system}.resolver;
  credentialNames = [
    "device-ca"
    "device-ca-key"
    "registration-cert"
    "registration-key"
    "native-ca"
    "native-client-cert"
    "native-client-key"
    "native-jwks"
    "front-ca"
  ];
  sources = names: lib.genAttrs names (name: "${f.runtime}-input/${name}");
  unitCredentials = names: lib.mapAttrsToList (name: path: "${name}:${path}") (sources names);
  jsonFile = name: value: pkgs.writeText name (builtins.toJSON value);
  resolverConfig = jsonFile "atrium-n03-resolver.json" f.resolver;
  registrationConfig = jsonFile "atrium-n03-registration.json" f.registration;
  declarations = jsonFile "atrium-n03-declarations.json" f;
  caddyFile = pkgs.writeText "atrium-n03-Caddyfile" (import ./caddy.nix { fixture = f; });
  privateNamespace = {
    NetworkNamespacePath = f.namespacePath;
    NoNewPrivileges = true;
    CapabilityBoundingSet = lib.mkForce [ "" ];
    AmbientCapabilities = lib.mkForce [ "" ];
    UnsetEnvironment = [ "SSLKEYLOGFILE" "SSL_CERT_FILE" "SSL_CERT_DIR" "HTTP_PROXY" "HTTPS_PROXY" "ALL_PROXY" ];
    ProtectProc = "invisible";
  };
  consumers = [ "atrium-resolver" "atrium-device-registration" "atrium-native-policy" "homelab-mcp" "whiskey-whiskey-whiskey" "caddy" "atrium-registration-entry" ];
  user = id: group: { isSystemUser = true; uid = id.uid; inherit group; };
in
{
  imports = [
    ./model-host.nix
    inputs.atrium.nixosModules.atrium
    inputs.homelab-mcp.nixosModules.default
    inputs.whiskey-whiskey-whiskey.nixosModules.default
  ];
  networking.hostName = "atrium-n03-fixture";
  boot.loader.grub.enable = false;
  fileSystems."/" = { device = "none"; fsType = "tmpfs"; };
  system.stateVersion = "25.11";

  assertions = [
    {
      assertion = config.networking.hostName == "atrium-n03-fixture";
      message = "N03 foundation is an unimported isolated fixture, never a production host.";
    }
    {
      assertion = inputs.atrium.rev == f.versions.atrium
        && inputs.homelab-mcp.rev == f.versions.native
        && inputs.whiskey-whiskey-whiskey.rev == f.versions.consumer;
      message = "N03 requires the exact accepted adapter and C8 implementation pins.";
    }
    {
      assertion = f.modelPlaneReady == config.services.atrium.runtime.reconciler.enable;
      message = "The isolated model plane and its real controller must be enabled coherently.";
    }
  ];

  services.atrium = {
    enable = true;
    registry = f.registry;
    runtime.resolver = {
      enable = true;
      package = resolverPackage;
      arguments = [ "--config" (toString resolverConfig) "serve" "--port" "18765" ];
      credentials = sources credentialNames;
    };
  };
  services.homelab-mcp = {
    enable = true;
    package = inputs.homelab-mcp.packages.${pkgs.system}.default;
    host = "127.0.0.1";
    port = f.port;
    publicBaseUrl = f.endpoints.native;
    environmentFile = "${f.runtime}-input/native-secrets.env";
    logLevel = "warning";
    onDemandDeploy.enable = false;
    actualSidecar.enable = false;
    financesExport.enable = false;
    settings = {
      HOMELAB_MCP_POCKETID_ISSUER = f.endpoints.identity;
      HOMELAB_MCP_POCKETID_CLIENT_ID = "atrium-n03-native";
      HOMELAB_MCP_ATRIUM_VIEW_POLICY = "/etc/atrium/desired-state/resolver.json";
      HOMELAB_MCP_ATRIUM_DENY = builtins.toJSON f.native.deny;
      HOMELAB_MCP_ATRIUM_POLICY = builtins.toJSON f.native.policy;
      HOMELAB_MCP_RESTRICTED_SCOPES = builtins.toJSON (lib.mapAttrs (_: scope: scope.tools)
        (lib.filterAttrs (name: scope: name != "admin" && scope.status == "active")
          f.generated.resolver.catalogs.home-mcp-fixture.scopes));
      HOMELAB_MCP_RESTRICTED_SCOPE_RESOURCES = builtins.toJSON (lib.mapAttrs (_: scope: scope.resources)
        (lib.filterAttrs (name: scope: name != "admin" && scope.status == "active")
          f.generated.resolver.catalogs.home-mcp-fixture.scopes));
      HOMELAB_MCP_GATUS_BASE_URL = "http://127.0.0.5:19101";
      HOMELAB_MCP_FINANCES_REPO_URL = "file://${f.state.native}/synthetic-finances-origin";
      HOMELAB_MCP_FINANCES_REPO_PATH = "${f.state.native}/synthetic-finances";
      HOMELAB_MCP_TRUSTED_PROXY_IPS = "127.0.0.1";
    };
  };
  services.whiskey-whiskey-whiskey = {
    enable = true;
    package = inputs.whiskey-whiskey-whiskey.packages.${pkgs.system}.default;
    host = "127.0.0.1";
    port = 13417;
    environmentFile = "${f.runtime}-input/whiskey-secrets.env";
    logLevel = "error";
    openFirewall = false;
    settings = {
      WWW_ATRIUM_CONFIG = "/etc/atrium/n03/whiskey.json";
      WWW_ATRIUM_MODEL_CONFIG = "/etc/atrium/n03/whiskey-model.json";
      WWW_EXTERNAL_AS_ISSUER = f.endpoints.identity;
      WWW_EXTERNAL_AS_RESOURCE = "atrium-isolated-fixture";
      WWW_OIDC_ISSUER = f.endpoints.identity;
      WWW_OIDC_CLIENT_ID = "atrium-n03-whiskey";
      WWW_OIDC_REDIRECT_URI = "${f.endpoints.whiskey}/api/auth/callback";
      WWW_PUBLIC_BASE_ORIGIN = f.endpoints.whiskey;
      NODE_EXTRA_CA_CERTS = "/run/credentials/whiskey-whiskey-whiskey.service/front-ca";
    };
  };
  services.caddy = {
    enable = true;
    configFile = caddyFile;
    adapter = "caddyfile";
  };

  users.groups = {
    atrium-resolver.gid = f.ids.atrium-resolver-fixture.gid;
    homelab-mcp.gid = f.ids.atrium-mcp-fixture.gid;
    atrium-consumer-fixture.gid = f.ids.atrium-consumer-fixture.gid;
    caddy.gid = lib.mkForce f.ids.atrium-caddy-fixture.gid;
    atrium-forwarder-fixture.gid = f.ids.atrium-forwarder-fixture.gid;
  };
  users.users = {
    atrium-resolver = user f.ids.atrium-resolver-fixture "atrium-resolver";
    homelab-mcp.uid = f.ids.atrium-mcp-fixture.uid;
    whiskey-whiskey-whiskey = user f.ids.atrium-consumer-fixture "atrium-consumer-fixture";
    caddy = {
      uid = lib.mkForce f.ids.atrium-caddy-fixture.uid;
      isSystemUser = true;
    };
    atrium-forwarder-fixture = user f.ids.atrium-forwarder-fixture "atrium-forwarder-fixture";
  };

  systemd.services = lib.genAttrs consumers
    (_: {
      requires = [ "atrium-n03-network.service" ];
      after = [ "atrium-n03-network.service" ];
      serviceConfig = privateNamespace;
    }) // {
    atrium-resolver = {
      requires = [ "atrium-n03-network.service" ];
      after = [ "atrium-n03-network.service" ];
      environment.NIX_SSL_CERT_FILE = "/run/credentials/atrium-resolver.service/front-ca";
      serviceConfig = privateNamespace // {
        DynamicUser = lib.mkForce false;
      };
    };
    atrium-device-registration = {
      description = "Isolated Atrium direct-peer device registration";
      requires = [ "atrium-n03-network.service" ];
      after = [ "atrium-n03-network.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = privateNamespace // {
        User = "atrium-resolver";
        Group = "atrium-resolver";
        ExecStart = "${lib.getExe resolverPackage} --config ${registrationConfig} serve-devices --port 18766";
        LoadCredential = unitCredentials credentialNames;
        StateDirectory = "atrium-resolver";
        StateDirectoryMode = "0700";
        UMask = "0077";
        ProtectSystem = "strict";
        ProtectHome = true;
        Restart = "on-failure";
      };
    };
    atrium-native-policy = {
      description = "Isolated retained-native current policy over direct service mTLS";
      requires = [ "atrium-n03-network.service" ];
      after = [ "atrium-n03-network.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = privateNamespace // {
        User = "atrium-resolver";
        Group = "atrium-resolver";
        ExecStart = "${lib.getExe resolverPackage} --config ${f.runtime}/native-policy.json serve-native-policy --port ${toString f.nativePolicyPort}";
        LoadCredential = unitCredentials [ "policy-server-cert" "policy-server-key" "policy-client-ca" "front-ca" ];
        StateDirectory = "atrium-resolver";
        StateDirectoryMode = "0700";
        UMask = "0077";
        ProtectSystem = "strict";
        ProtectHome = true;
        Restart = "on-failure";
      };
    };
    homelab-mcp = {
      requires = [ "atrium-n03-network.service" ];
      after = [ "atrium-n03-network.service" ];
      serviceConfig = privateNamespace // {
        LoadCredential = unitCredentials [
          "server-cert"
          "server-key"
          "resolver-client-ca"
          "resolver-jwks"
          "front-ca"
          "policy-ca"
          "policy-client-cert"
          "policy-client-key"
        ];
        EnvironmentFile = lib.mkForce [
          "${f.runtime}-input/native-secrets.env"
          "${f.runtime}/native-public.env"
        ];
      };
    };
    whiskey-whiskey-whiskey = {
      requires = [ "atrium-n03-network.service" "atrium-n03-whiskey-egress.service" ];
      after = [ "atrium-n03-network.service" "atrium-n03-whiskey-egress.service" ];
      serviceConfig = privateNamespace // {
        DynamicUser = lib.mkForce false;
        Group = "atrium-consumer-fixture";
        LoadCredential = unitCredentials [ "front-ca" ];
        UnsetEnvironment = privateNamespace.UnsetEnvironment ++ [ "ANTHROPIC_API_KEY" "ANTHROPIC_MODEL" ];
        ReadOnlyPaths = [ "${f.runtime}/delivery" ];
        ReadWritePaths = [ "${f.runtime}/acknowledgements/whiskey" ];
      };
    };
    caddy = {
      requires = [ "atrium-n03-network.service" ];
      after = [ "atrium-n03-network.service" ];
      serviceConfig = privateNamespace // {
        LoadCredential = unitCredentials [ "front-cert" "front-key" "native-ca" ];
        ExecReload = lib.mkForce "";
      };
    };
    atrium-registration-entry = {
      description = "Isolated TLS-byte forwarding, never proxy certificate assertions";
      requires = [ "atrium-n03-network.service" "atrium-device-registration.service" ];
      after = [ "atrium-n03-network.service" "atrium-device-registration.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = privateNamespace // {
        User = "atrium-forwarder-fixture";
        ExecStart = "${pkgs.socat}/bin/socat TCP4-LISTEN:${toString f.registrationPort},bind=${f.frontAddress},reuseaddr,fork TCP4:127.0.0.1:18766";
        Restart = "on-failure";
      };
    };
    atrium-n03-network = {
      description = "Require an invocation-owned N03 namespace before starting listeners";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        NetworkNamespacePath = f.namespacePath;
        CapabilityBoundingSet = [ "CAP_NET_ADMIN" ];
        ExecStart = pkgs.writeShellScript "atrium-n03-network" ''
          set -eu
          actual=$(${pkgs.coreutils}/bin/readlink /proc/self/ns/net)
          expected=$(${pkgs.coreutils}/bin/cat ${f.runtime}/namespace.identity)
          test "$actual" = "$expected"
          test "$actual" != "$(${pkgs.coreutils}/bin/readlink /proc/1/ns/net)"
          ${pkgs.iproute2}/bin/ip link set lo up
          ${pkgs.iproute2}/bin/ip address add ${f.frontAddress}/32 dev lo
        '';
      };
    };
    atrium-n03-whiskey-egress = {
      description = "Apply the existing N06 UID/address/port boundary in the owned N03 namespace";
      requires = [ "atrium-n03-network.service" ];
      after = [ "atrium-n03-network.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        NetworkNamespacePath = f.namespacePath;
        CapabilityBoundingSet = [ "CAP_NET_ADMIN" ];
        ExecStart = pkgs.writeShellScript "atrium-n03-whiskey-egress" ''
          set -eu
          expected=$(${pkgs.coreutils}/bin/cat ${f.runtime}/namespace.identity)
          exec ${pkgs.python3}/bin/python ${../atrium_n06/egress.py} \
            --policy ${jsonFile "atrium-n03-egress.json" f.egress} \
            --bindings ${f.runtime}/egress-bindings.json \
            --expected-netns "$expected" --nft ${pkgs.nftables}/bin/nft
        '';
      };
    };
  };
  environment.etc = {
    "atrium/n03/declarations.json".source = declarations;
    "atrium/n03/resolver.json".source = resolverConfig;
    "atrium/n03/registration.json".source = registrationConfig;
    "atrium/n03/native-policy-template.json".source = jsonFile "atrium-n03-native-policy-template.json" f.nativePolicy;
    "atrium/n03/whiskey.json".source = jsonFile "atrium-n03-whiskey.json" f.whiskey;
    "atrium/n03/whiskey-model.json".source = jsonFile "atrium-n03-whiskey-model.json" f.whiskeyModel;
    "atrium/n03/operations.json".source = jsonFile "atrium-n03-operations.json"
      (import ./operations.nix { fixture = f; inherit lib; });
  };
  # Split routing preserves the exact public MCP origin while R05 reaches its actual mTLS peer.
  networking.hosts = {
    "127.0.0.1" = [ f.names.native ];
    "${f.frontAddress}" = [ f.names.resolver f.names.whiskey f.names.identity f.names.models f.names.registration ];
  };
}
