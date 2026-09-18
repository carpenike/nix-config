{ config, inputs, pkgs, lib, mylib, ... }:
let
  cfg = config.services.atriumForge;
  composition = import ../atrium/configuration.nix { inherit config inputs pkgs lib mylib; };
  inherit (composition) packages runtime;
  m = composition.models;
  enabled = cfg.enable;
  native = enabled && cfg.adoption.native;
  whiskey = enabled && (cfg.adoption.whiskey || cfg.adoption.whiskeyText);
  text = enabled && cfg.adoption.whiskeyText;
  credentials = values: lib.mapAttrsToList (name: path: "${name}:${path}") values;
  projection = import ../atrium/credential-projection.nix { inherit lib; };
  projected = unit: values:
    (projection.serviceConfig { inherit pkgs unit; credentials = values; }) // {
      LoadCredential = credentials values;
    };
  policyProjection = projected "atrium-native-policy" runtime.policyCredentials;
  settingsProjection = projected "atrium-native-settings"
    (lib.getAttrs [ "native-profile" "resolver-client-cert" ] runtime.nativeCredentials);
  python = pkgs.python312.withPackages (ps: [ ps.cryptography ]);
  renderer = "${python}/bin/python ${../atrium/runtime-bindings.py}";
  nativePython = pkgs.python313.withPackages (ps: [
    (ps.toPythonModule config.services.homelab-mcp.package)
  ]);
  jsonFile = name: value: pkgs.writeText name (builtins.toJSON value);
  nativePreparationTemplate = runtime.native // {
    issuance = runtime.native.issuance // {
      policy_path = config.services.atrium.generated.resolver;
    };
  };
  nativePreparationPlan = jsonFile "atrium-native-preparation.json" {
    schema_version = 1;
    inherit (runtime) installation;
    native_template = jsonFile "atrium-native-preparation-template.json" nativePreparationTemplate;
    resolver_config = jsonFile "atrium-native-preparation-resolver.json" (runtime.bootstrap // {
      policy_path = config.services.atrium.generated.resolver;
    });
    enrollment = jsonFile "atrium-native-preparation-enrollment.json" composition.bootstrap.enrollment;
    tls_plan = jsonFile "atrium-native-preparation-tls.json" runtime.tlsPlan;
    policy_directory = runtime.paths.policy;
    native_signing_key = config.systemd.services.homelab-mcp.environment.HOMELAB_MCP_OAUTH_SIGNING_KEY_PATH;
    native_oauth_database = config.systemd.services.homelab-mcp.environment.HOMELAB_MCP_OAUTH_STATE_DB_PATH;
    native_identity = config.systemd.services.homelab-mcp.serviceConfig.User;
    resolver_identity = lib.getAttrs [ "uid" "gid" ] mylib.serviceUids.atrium-resolver;
    trust_identity = lib.getAttrs [ "uid" "gid" ] mylib.serviceUids.atrium-trust;
    resolver_command = resolver;
    native_bootstrap = ../atrium/native-bootstrap.py;
    native_bootstrap_config = jsonFile "atrium-native-preparation-deny.json" {
      inherit (runtime) installation;
      native_issuer = runtime.endpoints.native;
      inherit (runtime.native) deny;
    };
    finance_grants = jsonFile "atrium-native-preparation-grants.json" composition.bootstrap.financeClients;
    native_issuer = runtime.endpoints.native;
    native_jwks_url = "${runtime.endpoints.native}/oauth/jwks.json";
    resolver_jwks_url = "${runtime.endpoints.resolver}/.well-known/jwks.json";
  };
  nativePreparation = pkgs.writeShellApplication {
    name = "atrium-native-prepare";
    runtimeInputs = [ nativePython ];
    text = ''
      exec ${nativePython}/bin/python -I -B ${../atrium/native-cutover.py} "$@" --config ${nativePreparationPlan}
    '';
  };
  whiskeyPreparationPlan = jsonFile "atrium-whiskey-preparation.json" {
    schema_version = 1;
    inherit (runtime) installation;
    policy_directory = runtime.paths.policy;
    legacy_deny_directory = "/var/lib/whiskey-whiskey-whiskey/atrium-admission";
    settings = runtime.whiskey;
    model = m.whiskey;
    identity = {
      uid = m.roles.whiskey.uid;
      gid = m.deliveryGroup.gid;
      user = m.roles.whiskey.name;
      group = m.deliveryGroup.name;
    };
    image_credentials = imageCredentials;
    egress = whiskeyNetwork;
    network_helper = ../atrium/whiskey-network.py;
    model_approval = "${runtime.paths.policy}/model-adoption.approved";
    node = "${pkgs.nodejs_22}/bin/node";
    bootstrap = ../atrium/whiskey-bootstrap.mjs;
    bootstrap_config = jsonFile "atrium-whiskey-preparation-deny.json" {
      inherit (runtime) installation;
      settings = runtime.whiskey;
      store_module = "${config.services.whiskey-whiskey-whiskey.package}/share/whiskey-whiskey-whiskey/dist/server/lib/atrium-deny-store.js";
    };
  };
  whiskeyPreparation = pkgs.writeShellApplication {
    name = "atrium-whiskey-prepare";
    runtimeInputs = [ pkgs.python312 ];
    text = ''
      exec ${pkgs.python312}/bin/python -I -B ${../atrium/whiskey-cutover.py} "$@" --config ${whiskeyPreparationPlan}
    '';
  };
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  securityProtection = {
    class = "critical";
    objectives = { onsiteRpoSeconds = 900; offsiteRpoSeconds = 86400; rtoSeconds = 7200; };
    requiredTiers = [ "local-snapshot" "replication" "nas-backup" "offsite-backup" ];
    consistency = "crash-consistent";
    validator = null;
    allowEmptyBootstrap = false;
  };
  resolver = lib.getExe packages.resolver;
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
  imageCredentials = {
    image-openai = config.sops.secrets."whiskey-whiskey-whiskey/openai_api_key".path;
    image-gemini = config.sops.secrets."whiskey-whiskey-whiskey/gemini_api_key".path;
    image-openrouter = config.sops.secrets."whiskey-whiskey-whiskey/openrouter_api_key".path;
  };
  outputRules = lib.optionals native [
    "-o lo -d 127.0.0.1 -p tcp --dport ${toString runtime.ports.nativePolicy} -m owner ! --uid-owner homelab-mcp -j REJECT --reject-with tcp-reset"
  ] ++ lib.optional whiskey
    "-o lo -d 127.0.0.1 -p tcp --dport 3417 -m owner ! --uid-owner ${toString mylib.serviceUids.caddy.uid} -j REJECT --reject-with tcp-reset";
  fixedWhiskeyHosts = [
    "llm.holthome.net"
    "atrium.holthome.net"
    "id.holthome.net"
    "api.openai.com"
    "generativelanguage.googleapis.com"
    "openrouter.ai"
    "api.partiful.com"
    "securetoken.googleapis.com"
    "firestore.googleapis.com"
    "firebasestorage.googleapis.com"
    "plex.holthome.net"
    "cook.holthome.net"
    "api.mailgun.net"
    "api.pushover.net"
  ];
  nativeOutputRule = "-o lo -d 127.0.0.1 -p tcp --dport 9200 -j ATRIUM-NATIVE";
  nativeFirewall = pkgs.writeText "atrium-native-private.rules" ''
    *filter
    :ATRIUM-NATIVE - [0:0]
    -F ATRIUM-NATIVE
    -A ATRIUM-NATIVE -m owner --uid-owner ${toString mylib.serviceUids.caddy.uid} -j RETURN
    -A ATRIUM-NATIVE -m owner --uid-owner ${toString mylib.serviceUids.atrium-resolver.uid} -j RETURN
    -A ATRIUM-NATIVE -j REJECT --reject-with tcp-reset
    COMMIT
  '';
  egressHosts = lib.unique (fixedWhiskeyHosts ++ lib.concatLists (builtins.attrValues cfg.whiskeyEgress.dynamicHosts));
  whiskeyNetwork = {
    hosts = egressHosts;
    dns_addresses = cfg.whiskeyEgress.dnsAddresses;
    uid = m.roles.whiskey.uid;
  };
  networkCommand = "${pkgs.python312}/bin/python -I -B ${../atrium/whiskey-network.py}"
    + " --config ${jsonFile "atrium-whiskey-network.json" whiskeyNetwork}"
    + " --iptables-restore ${pkgs.iptables}/bin/iptables-restore"
    + " --iptables ${pkgs.iptables}/bin/iptables"
    + " --ip6tables ${pkgs.iptables}/bin/ip6tables";
in
{
  options.services.atriumForge.whiskeyEgress = {
    dnsAddresses = lib.mkOption {
      type = lib.types.listOf (lib.types.strMatching "[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+");
      default = [ ];
      description = "Exact reviewed DNS resolver IPv4 addresses for the adopted Whiskey process.";
    };
    dynamicHosts = lib.mkOption {
      type = lib.types.submodule {
        options = lib.genAttrs [ "calendar" "media" "webpush" ] (name: lib.mkOption {
          type = lib.types.listOf (lib.types.strMatching "[a-z0-9][a-z0-9.-]*\\.[a-z][a-z0-9-]*");
          default = [ ];
          description = "Reviewed hostname-only ${name} and redirect destinations; never raw capability URLs.";
        });
      };
      default = { };
      description = "Explicit inventories for destination classes not fully declared in existing source.";
    };
  };
  config = lib.mkMerge [
    (lib.mkIf enabled {
      system.build.atriumNativePreparation = nativePreparation;
      environment.systemPackages = [ nativePreparation ];
      assertions = [
        {
          assertion = !cfg.adoption.whiskey || cfg.adoption.whiskeyText;
          message = "Whiskey Atrium-route adoption requires its domain-owned text path and enforced egress.";
        }
        {
          assertion = !cfg.adoption.whiskeyText || cfg.adoption.models;
          message = "Whiskey text adoption requires real owned-model reconciliation and admission.";
        }
      ];
      environment.etc = {
        "atrium/bootstrap/native-cutover.json".text = nativePreparationPlan.text;
        "atrium/runtime/native-policy.template.json".text = builtins.toJSON runtime.nativePolicyTemplate;
        "atrium/runtime/native.template.json".text = builtins.toJSON runtime.native;
        "atrium/runtime/whiskey.json".text = builtins.toJSON runtime.whiskey;
        "atrium/runtime/whiskey-egress.json".text = builtins.toJSON {
          schema_version = 1;
          environment = "production";
          policy = "atrium-forge-whiskey-egress";
          enforcement = "ipv4-address-and-port";
          required_fixed_hosts = fixedWhiskeyHosts;
          dynamic_hosts = cfg.whiskeyEgress.dynamicHosts;
          dns_addresses = cfg.whiskeyEgress.dnsAddresses;
          address_binding = "complete-dns-resolution-of-declared-hosts-only";
          address_refresh_seconds = 60;
          automatic_hostname_widening = false;
          undeclared_egress = "deny";
        };
      };
    })
    (lib.mkIf (native || whiskey) {
      networking.firewall = {
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
    })
    (lib.mkIf native {
      networking.firewall = {
        extraCommands = ''
          ${pkgs.iptables}/bin/iptables-restore --wait --noflush < ${nativeFirewall}
          ${pkgs.iptables}/bin/iptables -C OUTPUT ${nativeOutputRule} 2>/dev/null \
            || ${pkgs.iptables}/bin/iptables -I OUTPUT ${nativeOutputRule}
        '';
        extraStopCommands = ''
          ${pkgs.iptables}/bin/iptables -D OUTPUT ${nativeOutputRule} 2>/dev/null || true
          ${pkgs.iptables}/bin/iptables -F ATRIUM-NATIVE 2>/dev/null || true
          ${pkgs.iptables}/bin/iptables -X ATRIUM-NATIVE 2>/dev/null || true
        '';
      };
      environment.etc."atrium/bootstrap/native-deny.json".text = builtins.toJSON {
        inherit (runtime) installation;
        native_issuer = runtime.endpoints.native;
        inherit (runtime.native) deny;
      };
      services.homelab-mcp.settings = {
        HOMELAB_MCP_ATRIUM_VIEW_POLICY = "/etc/atrium/desired-state/resolver.json";
      };
      systemd.services = {
        atrium-native-deny-initialize = {
          description = "Explicit first-use native deny history, without issuing or migrating credentials";
          requires = [ "zfs-service-datasets.service" ];
          after = [ "zfs-service-datasets.service" ];
          unitConfig.RequiresMountsFor = [ "/var/lib/homelab-mcp" ];
          serviceConfig = hardened // {
            Type = "oneshot";
            User = "homelab-mcp";
            Group = "homelab-mcp";
            ReadWritePaths = [ "/var/lib/homelab-mcp" ];
            PrivateNetwork = true;
            ExecStart = "${nativePython}/bin/python ${../atrium/native-bootstrap.py} --config /etc/atrium/bootstrap/native-deny.json --confirm-new-installation ${runtime.installation}";
          };
        };
        atrium-native-policy = {
          description = "Atrium current native policy over direct, exact-peer service mTLS";
          wantedBy = [ "multi-user.target" ];
          requires = [ "firewall.service" "zfs-service-datasets.service" ];
          after = [ "firewall.service" "zfs-service-datasets.service" "network-online.target" ];
          restartTriggers = [
            config.services.atrium.generated.resolver
            config.environment.etc."atrium/runtime/native-policy.template.json".source
          ];
          unitConfig = {
            RequiresMountsFor = [ runtime.paths.resolver runtime.paths.trust runtime.paths.policy ];
            AssertFileNotEmpty = [
              "${runtime.paths.resolver}/foundation.initialized"
              "${runtime.paths.resolver}/resolver.sqlite3"
              "${runtime.paths.policy}/native-adoption.approved"
            ];
          };
          serviceConfig = hardened // policyProjection // {
            User = "atrium-resolver";
            Group = "atrium-resolver";
            StateDirectory = "atrium-resolver";
            StateDirectoryMode = "0700";
            RuntimeDirectory = [ "atrium-native-policy" policyProjection.RuntimeDirectory ];
            ReadWritePaths = [ runtime.paths.resolver ];
            ExecStartPre = policyProjection.ExecStartPre ++ [
              "${renderer} native-policy --template /etc/atrium/runtime/native-policy.template.json --client-certificate ${projection.path "atrium-native-policy" "policy-client-cert"} --output /run/atrium-native-policy/settings.json"
            ];
            ExecStart = "${resolver} --config /run/atrium-native-policy/settings.json serve-native-policy --port ${toString runtime.ports.nativePolicy}";
            Restart = "on-failure";
            RestartSec = "10s";
          };
        };
        atrium-native-settings = {
          description = "Bind explicit native cutover and real resolver TLS leaf, without migrating grants";
          partOf = [ "homelab-mcp.service" ];
          requires = [ "zfs-service-datasets.service" ];
          after = [ "zfs-service-datasets.service" ];
          restartTriggers = [
            config.services.atrium.generated.resolver
            config.environment.etc."atrium/runtime/native.template.json".source
          ];
          unitConfig = {
            RequiresMountsFor = [ runtime.paths.policy runtime.paths.trust "/var/lib/homelab-mcp" ];
            AssertFileNotEmpty = [ "${runtime.paths.policy}/native-adoption.approved" ];
          };
          serviceConfig = hardened // settingsProjection // {
            Type = "oneshot";
            RemainAfterExit = true;
            User = "homelab-mcp";
            Group = "homelab-mcp";
            RuntimeDirectory = [ "atrium-native-mcp" settingsProjection.RuntimeDirectory ];
            ExecStart = "${renderer} native-environment --template /etc/atrium/runtime/native.template.json --profile ${projection.path "atrium-native-settings" "native-profile"} --client-certificate ${projection.path "atrium-native-settings" "resolver-client-cert"} --output /run/atrium-native-mcp/native.env";
            PrivateNetwork = true;
          };
        };
        homelab-mcp = {
          requires = [ "firewall.service" "atrium-native-settings.service" "atrium-native-policy.service" ];
          after = [ "firewall.service" "atrium-native-settings.service" "atrium-native-policy.service" ];
          restartTriggers = [ config.services.atrium.generated.resolver ];
          unitConfig.AssertFileNotEmpty = [
            "${runtime.paths.policy}/native-adoption.approved"
            "${runtime.native.deny.state_directory}/owner.json"
            "${runtime.native.deny.state_directory}/denial.sqlite"
          ];
          serviceConfig = (projected "homelab-mcp" runtime.nativeCredentials) // {
            EnvironmentFile = lib.mkForce (lib.mkAfter [ "/run/atrium-native-mcp/native.env" ]);
            UnsetEnvironment = [ "SSLKEYLOGFILE" "HTTP_PROXY" "HTTPS_PROXY" "ALL_PROXY" ];
          };
        };
        caddy.serviceConfig.LoadCredential = [
          "atrium-native-ca:${runtime.paths.trust}/native-ca.crt.pem"
        ];
      };
      modules.services.caddy.virtualHosts.homelab-mcp.backend.scheme = "https";
      modules.services.caddy.virtualHosts.homelab-mcp.reverseProxyBlock = lib.mkAfter ''
        transport http {
          tls
          tls_server_name mcp.holthome.net
          tls_trust_pool file /run/credentials/caddy.service/atrium-native-ca
        }
      '';
      modules.alerting.rules.atrium-native-policy-down =
        forgeDefaults.mkSystemdServiceDownAlert
          "atrium-native-policy" "AtriumNativePolicy" "native current-policy authorization";
      modules.storage.datasets.services.homelab-mcp.protection = securityProtection;
      modules.services.backup.restic.jobs.atrium-native-security-offsite =
        (forgeDefaults.mkBackupWithTags "homelab-mcp" [ "atrium" "native-security-history" "offsite" "forge" ]) // {
          repository = "r2-offsite";
          paths = [ "/var/lib/homelab-mcp" ];
        };
    })
    (lib.mkIf whiskey {
      system.build.atriumWhiskeyPreparation = whiskeyPreparation;
      environment.systemPackages = [ whiskeyPreparation ];
      environment.etc."atrium/bootstrap/whiskey-cutover.json".text = whiskeyPreparationPlan.text;
      users.groups.whiskey-whiskey-whiskey.gid = m.roles.whiskey.gid;
      users.users.whiskey-whiskey-whiskey = {
        isSystemUser = true;
        uid = m.roles.whiskey.uid;
        group = "whiskey-whiskey-whiskey";
        extraGroups = [ m.deliveryGroup.name ];
      };
      systemd.services.whiskey-whiskey-whiskey = {
        requires = [ "firewall.service" ];
        after = [ "firewall.service" ];
        unitConfig.AssertFileNotEmpty = [ "${runtime.paths.policy}/whiskey-adoption.approved" ];
        serviceConfig = {
          # A declared NSS account fixes the UID while retaining the existing
          # private/id-mapped StateDirectory layout and its application data.
          DynamicUser = lib.mkForce true;
          Group = m.deliveryGroup.name;
          NoNewPrivileges = true;
          CapabilityBoundingSet = lib.mkForce [ "" ];
          AmbientCapabilities = lib.mkForce [ "" ];
        };
      };
      systemd.services."whiskey-www-maintenance@".serviceConfig = {
        DynamicUser = lib.mkForce true;
        Group = m.deliveryGroup.name;
      };
      modules.services.caddy.extraConfig = ''
        http://127.0.0.1:${toString runtime.ports.whiskeyMetrics} {
          ${import ../atrium/whiskey-metrics.nix { }}
        }
      '';
    })
    (lib.mkIf (enabled && cfg.adoption.whiskey) {
      services.whiskey-whiskey-whiskey.settings.WWW_ATRIUM_CONFIG = "/etc/atrium/runtime/whiskey.json";
      environment.etc."atrium/bootstrap/whiskey-deny.json".text = builtins.toJSON {
        inherit (runtime) installation;
        settings = runtime.whiskey;
        store_module = "${config.services.whiskey-whiskey-whiskey.package}/share/whiskey-whiskey-whiskey/dist/server/lib/atrium-deny-store.js";
      };
      systemd.services.atrium-whiskey-deny-initialize = {
        description = "Explicit first-use Whiskey deny history without starting household services";
        requires = [ "zfs-service-datasets.service" ];
        after = [ "zfs-service-datasets.service" ];
        unitConfig.RequiresMountsFor = [ "/var/lib/whiskey-whiskey-whiskey" ];
        serviceConfig = hardened // {
          Type = "oneshot";
          User = m.roles.whiskey.name;
          Group = m.deliveryGroup.name;
          ReadWritePaths = [ runtime.whiskey.deny.state_directory ];
          PrivateNetwork = true;
          ExecStart = "${pkgs.nodejs_22}/bin/node ${../atrium/whiskey-bootstrap.mjs} --config /etc/atrium/bootstrap/whiskey-deny.json --confirm-new-installation ${runtime.installation}";
        };
      };
      systemd.services.whiskey-whiskey-whiskey.restartTriggers = [
        config.environment.etc."atrium/runtime/whiskey.json".source
      ];
      systemd.services.whiskey-whiskey-whiskey.serviceConfig.ReadWritePaths = [
        runtime.whiskey.deny.state_directory
      ];
      systemd.services.whiskey-whiskey-whiskey.unitConfig.AssertFileNotEmpty = [
        "${runtime.whiskey.deny.state_directory}/owner.json"
        "${runtime.whiskey.deny.state_directory}/admission.sqlite"
      ];
      modules.storage.datasets.services.whiskeywhiskeywhiskey.protection = securityProtection;
      modules.services.backup.restic.jobs.atrium-whiskey-security-offsite =
        (forgeDefaults.mkBackupWithTags "whiskeywhiskeywhiskey" [ "atrium" "whiskey-security-history" "offsite" "forge" ]) // {
          repository = "r2-offsite";
          paths = [ "/var/lib/whiskey-whiskey-whiskey" ];
        };
    })
    (lib.mkIf text {
      assertions = [{
        assertion = cfg.whiskeyEgress.dnsAddresses != [ ];
        message = "Whiskey text adoption needs reviewed DNS resolvers and exact configured destination hostnames; inactive destination classes may be empty, never wildcarded.";
      }];
      services.whiskey-whiskey-whiskey.settings.WWW_ATRIUM_MODEL_CONFIG = "/etc/atrium/runtime/whiskey-model.json";
      systemd.tmpfiles.rules = [
        "d /run/atrium-acknowledgements/whiskey 0750 ${m.roles.whiskey.name} ${m.deliveryGroup.name} -"
      ];
      environment.etc."atrium/runtime/whiskey-images.template.json".text = builtins.toJSON {
        OPENAI_API_KEY = "/run/credentials/atrium-whiskey-images.service/image-openai";
        GEMINI_API_KEY = "/run/credentials/atrium-whiskey-images.service/image-gemini";
        OPENROUTER_API_KEY = "/run/credentials/atrium-whiskey-images.service/image-openrouter";
      };
      systemd.services = {
        atrium-whiskey-images = {
          description = "Load only explicitly provisioned Personal image-provider credentials";
          partOf = [ "whiskey-whiskey-whiskey.service" ];
          restartTriggers = [ config.environment.etc."atrium/runtime/whiskey-images.template.json".source ];
          serviceConfig = hardened // {
            Type = "oneshot";
            RemainAfterExit = true;
            User = m.roles.whiskey.name;
            Group = "whiskey-whiskey-whiskey";
            RuntimeDirectory = "atrium-whiskey-images";
            RuntimeDirectoryMode = "0700";
            LoadCredential = credentials imageCredentials;
            ExecStart = "${renderer} whiskey-images --template /etc/atrium/runtime/whiskey-images.template.json --output /run/atrium-whiskey-images/images.env";
            PrivateNetwork = true;
          };
        };
        atrium-whiskey-egress = {
          description = "Install the explicitly reviewed Whiskey IPv4 destination/port ceiling";
          requires = [ "firewall.service" ];
          wants = [ "network-online.target" ];
          after = [ "firewall.service" "network-online.target" ];
          before = [ "whiskey-whiskey-whiskey.service" ];
          restartTriggers = [ config.environment.etc."atrium/runtime/whiskey-egress.json".source ];
          script = ''
            exec ${networkCommand}
          '';
          preStop = ''
            ${pkgs.iptables}/bin/iptables -D OUTPUT -m owner --uid-owner ${toString m.roles.whiskey.uid} -j ATRIUM-WHISKEY 2>/dev/null || true
            ${pkgs.iptables}/bin/ip6tables -D OUTPUT -m owner --uid-owner ${toString m.roles.whiskey.uid} -j REJECT 2>/dev/null || true
            ${pkgs.iptables}/bin/iptables -F ATRIUM-WHISKEY 2>/dev/null || true
            ${pkgs.iptables}/bin/iptables -X ATRIUM-WHISKEY 2>/dev/null || true
          '';
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            NoNewPrivileges = true;
            CapabilityBoundingSet = [ "CAP_NET_ADMIN" ];
          };
        };
        atrium-whiskey-egress-refresh = {
          description = "Refresh addresses for declared Whiskey destinations without widening hostnames";
          requires = [ "atrium-whiskey-egress.service" ];
          after = [ "atrium-whiskey-egress.service" ];
          serviceConfig = hardened // {
            Type = "oneshot";
            ExecStart = networkCommand;
            CapabilityBoundingSet = [ "CAP_NET_ADMIN" ];
          };
        };
        whiskey-whiskey-whiskey = {
          requires = [ "atrium-whiskey-egress.service" "atrium-whiskey-images.service" ];
          after = [ "atrium-whiskey-egress.service" "atrium-whiskey-images.service" ];
          restartTriggers = [
            config.environment.etc."atrium/runtime/whiskey-model.json".source
            config.environment.etc."atrium/runtime/whiskey-egress.json".source
          ];
          serviceConfig = {
            EnvironmentFile = lib.mkAfter [ "/run/atrium-whiskey-images/images.env" ];
            UnsetEnvironment = [ "ANTHROPIC_API_KEY" "ANTHROPIC_MODEL" "SSLKEYLOGFILE" "HTTP_PROXY" "HTTPS_PROXY" "ALL_PROXY" ];
            ReadOnlyPaths = [ "/run/atrium-delivery/whiskey" ];
            ReadWritePaths = [ "/run/atrium-acknowledgements/whiskey" ];
          };
        };
        "whiskey-www-maintenance@" = {
          requires = [ "atrium-whiskey-egress.service" ];
          after = [ "atrium-whiskey-egress.service" ];
          environment.WWW_ATRIUM_MODEL_CONFIG = "/etc/atrium/runtime/whiskey-model.json";
          serviceConfig = {
            UnsetEnvironment = [ "ANTHROPIC_API_KEY" "ANTHROPIC_MODEL" "SSLKEYLOGFILE" "HTTP_PROXY" "HTTPS_PROXY" "ALL_PROXY" ];
            ReadOnlyPaths = [ "/run/atrium-delivery/whiskey" ];
            ReadWritePaths = [ "/run/atrium-acknowledgements/whiskey" ];
          };
        };
      };
      systemd.timers.atrium-whiskey-egress-refresh = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "1m";
          OnUnitActiveSec = "1m";
          Unit = "atrium-whiskey-egress-refresh.service";
        };
      };
    })
  ];
}
