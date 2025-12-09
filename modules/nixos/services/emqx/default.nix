{ lib, mylib, pkgs, config, podmanLib, ... }:
with lib;
let
  sharedTypes = mylib.types;
  storageHelpers = import ../../storage/helpers-lib.nix { inherit pkgs lib; };
  mqttUserType = types.submodule {
    options = {
      username = mkOption {
        type = types.str;
        description = "MQTT username.";
      };
      passwordFile = mkOption {
        type = types.path;
        description = "Path to the SOPS secret containing the MQTT user's password.";
      };
      tags = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Optional tags applied to this MQTT user.";
      };
    };
  };

  aclRuleType = types.submodule {
    options = {
      permission = mkOption {
        type = types.enum [ "allow" "deny" ];
        default = "allow";
        description = "Whether to allow or deny matching actions.";
      };
      action = mkOption {
        type = types.enum [ "publish" "subscribe" "all" "pubsub" ];
        default = "pubsub";
        description = "MQTT action the rule applies to.";
      };
      subject = mkOption {
        type = types.submodule {
          options = {
            kind = mkOption {
              type = types.enum [ "user" "clientid" "ipaddr" "all" ];
              default = "user";
              description = "Principal type to match.";
            };
            value = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "Principal identifier (ignored when kind = all).";
            };
          };
        };
        default = { };
        description = "Principal selector for the ACL rule.";
      };
      topics = mkOption {
        type = types.listOf types.str;
        description = "One or more topic filters (wildcards supported).";
      };
      comment = mkOption {
        type = types.str;
        default = "";
        description = "Optional comment injected above the rule in authz.conf.";
      };
    };
  };

  integrationSubmoduleType = types.submodule {
    options = {
      users = mkOption {
        type = types.listOf mqttUserType;
        default = [ ];
        description = "MQTT users contributed by this integration.";
      };
      acls = mkOption {
        type = types.listOf aclRuleType;
        default = [ ];
        description = "Topic ACL rules contributed by this integration.";
      };
    };
  };

  cfg = config.modules.services.emqx;
  notificationsCfg = config.modules.notifications or { };
  hasCentralizedNotifications = notificationsCfg.enable or false;

  serviceName = "emqx";
  backend = config.virtualisation.oci-containers.backend;
  serviceAttrName = "${backend}-${serviceName}";
  serviceUnit = "${serviceAttrName}.service";
  envfileServiceAttrName = "${backend}-${serviceName}-envfile";
  envfileServiceUnit = "${envfileServiceAttrName}.service";

  storageCfg = config.modules.storage or { };
  datasetsCfg = storageCfg.datasets or { };
  defaultDatasetPath =
    if datasetsCfg ? parentDataset then
      "${datasetsCfg.parentDataset}/${serviceName}"
    else
      null;

  datasetPath = cfg.datasetPath or defaultDatasetPath;

  envDir = "/run/${serviceName}";
  envFile = "${envDir}/env";

  sanitize = str: lib.replaceStrings [ " " "/" ":" "@" "." ] [ "_" "_" "_" "_" "_" ] str;

  integrationValues = lib.attrValues cfg.integrations;
  contributedUsers = lib.concatMap (integration: integration.users) integrationValues;
  allUsers = cfg.users ++ contributedUsers;

  aclRules = cfg.aclRules ++ lib.concatMap (integration: integration.acls) integrationValues;

  authorizationEnabled = (cfg.authorization.enable or false) || (aclRules != [ ]);
  aclFile = "${cfg.dataDir}/authz.conf";

  renderAclRule = rule:
    let
      subjectValue = rule.subject.value or "";
      subjectExpr =
        if rule.subject.kind == "all" then
          "all"
        else if subjectValue == "" then
          throw "modules.services.emqx: ACL rule with kind '${rule.subject.kind}' requires a non-empty subject value"
        else
          "{${rule.subject.kind}, \"${subjectValue}\"}";
      topicsExpr =
        if rule.topics == [ ] then
          throw "modules.services.emqx: ACL rule for ${subjectExpr} must specify at least one topic"
        else
          "[" + (lib.concatStringsSep ", " (map (topic: "\"${topic}\"") rule.topics)) + "]";
      renderSingle = singleRule:
        let
          comment = if singleRule.comment == "" then "" else "% ${singleRule.comment}\n";
        in
        "${comment}{${singleRule.permission}, ${subjectExpr}, ${singleRule.action}, ${topicsExpr}}.\n";
    in
    if rule.action == "pubsub" then
      (renderSingle (rule // { action = "publish"; }))
      + (renderSingle (rule // { action = "subscribe"; comment = ""; }))
    else
      renderSingle rule;

  aclFileContents = lib.concatMapStrings renderAclRule aclRules;

  userEntries = lib.imap1
    (idx: user: {
      index = idx;
      username = user.username;
      credentialName = "emqx_user_${sanitize user.username}_${toString idx}";
      passwordFile = user.passwordFile;
      tags = user.tags or [ ];
    })
    allUsers;

  boolString = value: if value then "true" else "false";

  dashboardContainerBindAddress =
    if cfg.dashboard.listenAddress == "127.0.0.1" || cfg.dashboard.listenAddress == "localhost" then
      "0.0.0.0"
    else
      cfg.dashboard.listenAddress;

in
{
  options.modules.services.emqx = {
    enable = mkEnableOption "EMQX MQTT broker";

    image = mkOption {
      type = types.str;
      default = "emqx/emqx:5.8.3@sha256:2bb94239a3812cd3443695d29d196cff510660b3fbf1bc56bbd8747fa94c4bd8";
      description = "Container image (tag or digest) used for EMQX.";
    };

    user = mkOption {
      type = types.str;
      default = "emqx";
      description = "System user that owns EMQX state and bind-mounted data.";
    };

    group = mkOption {
      type = types.str;
      default = "emqx";
      description = "Primary group for EMQX data.";
    };

    dataDir = mkOption {
      type = types.path;
      default = "/var/lib/emqx";
      description = "Persistent data directory mounted into the container (maps to /opt/emqx/data).";
    };

    datasetPath = mkOption {
      type = types.nullOr types.str;
      default = defaultDatasetPath;
      example = "tank/services/emqx";
      description = "Optional ZFS dataset path used for EMQX persistence and replication.";
    };

    podmanNetwork = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Attach the EMQX container to a specific Podman network (defaults to host port publishing).";
    };

    timezone = mkOption {
      type = types.str;
      default = config.time.timeZone or "UTC";
      description = "Timezone passed to the container.";
    };

    allowAnonymous = mkOption {
      type = types.bool;
      default = false;
      description = "Whether anonymous MQTT connections are permitted.";
    };

    nodeName = mkOption {
      type = types.str;
      default = "${serviceName}@${config.networking.hostName}";
      description = "EMQX node name (format: name@host).";
    };
    nodeCookie = mkOption {
      type = types.str;
      default = lib.substring 0 64 (builtins.hashString "sha256" config.networking.hostName);
      description = "Erlang cookie used for cluster authentication (must match across nodes).";
    };

    listeners = {
      mqtt = {
        host = mkOption {
          type = types.str;
          default = "0.0.0.0";
          description = "Address EMQX should bind for TCP MQTT traffic.";
        };
        port = mkOption {
          type = types.port;
          default = 1883;
          description = "Port exposed for MQTT clients.";
        };
        maxConnections = mkOption {
          type = types.ints.positive;
          default = 2048;
          description = "Maximum concurrent MQTT client connections.";
        };
      };

      websocket = {
        enable = mkEnableOption "MQTT over WebSocket listener" // { default = false; };
        host = mkOption {
          type = types.str;
          default = "0.0.0.0";
          description = "Address EMQX should bind for the WebSocket listener.";
        };
        port = mkOption {
          type = types.port;
          default = 8083;
          description = "Port exposed for MQTT over WebSocket.";
        };
      };
    };

    dashboard = {
      enable = mkEnableOption "EMQX dashboard" // { default = true; };
      listenAddress = mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = "Address EMQX dashboard should bind.";
      };
      port = mkOption {
        type = types.port;
        default = 18083;
        description = "Dashboard HTTP port.";
      };
      username = mkOption {
        type = types.str;
        default = "admin";
        description = "Dashboard login username.";
      };
      passwordFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "SOPS-managed secret containing the dashboard admin password.";
      };
      reverseProxy = mkOption {
        type = types.nullOr sharedTypes.reverseProxySubmodule;
        default = null;
        description = "Optional reverse proxy registration for the dashboard.";
      };

    };

    users = mkOption {
      type = types.listOf mqttUserType;
      default = [ ];
      description = "Static MQTT users provisioned via built-in authentication.";
    };

    aclRules = mkOption {
      type = types.listOf aclRuleType;
      default = [ ];
      description = "Static topic ACL rules enforced by the built-in authorization database.";
    };

    authorization = {
      enable = mkEnableOption "EMQX built-in authorization" // { default = false; };
      noMatch = mkOption {
        type = types.enum [ "allow" "deny" ];
        default = "allow";
        description = "Default action when no ACL rule matches.";
      };
    };

    integrations = mkOption {
      type = types.attrsOf integrationSubmoduleType;
      default = { };
      description = "Downstream services can contribute MQTT users and ACL rules via this attribute set.";
    };

    resources = mkOption {
      type = types.nullOr sharedTypes.containerResourcesSubmodule;
      default = {
        memory = "512m";
        memoryReservation = "256m";
        cpus = "0.5"; # 50% of one CPU core
      };
      description = "Podman resource limits applied to EMQX.";
    };

    healthcheck = mkOption {
      type = types.nullOr sharedTypes.healthcheckSubmodule;
      default = {
        enable = true;
        interval = "30s";
        timeout = "10s";
        retries = 3;
        startPeriod = "60s";
      };
      description = "Container healthcheck configuration.";
    };

    backup = mkOption {
      type = types.nullOr sharedTypes.backupSubmodule;
      default = null;
      description = "Optional Restic backup policy for EMQX data.";
    };

    notifications = mkOption {
      type = types.nullOr sharedTypes.notificationSubmodule;
      default = {
        enable = true;
        channels.onFailure = [ "system-alerts" ];
        customMessages.failure = "EMQX broker failed on ${config.networking.hostName}";
      };
      description = "Notification hooks for EMQX failures.";
    };

    preseed = {
      enable = mkEnableOption "automatic restore before EMQX starts";
      repositoryUrl = mkOption {
        type = types.str;
        default = "";
        description = "Restic repository used for dataset preseed.";
      };
      passwordFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "Restic password file.";
      };
      environmentFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "Optional environment file for Restic backend credentials.";
      };
      restoreMethods = mkOption {
        type = types.listOf (types.enum [ "syncoid" "local" "restic" ]);
        default = [ "syncoid" "local" "restic" ];
        description = "Ordered list of restore methods attempted by the preseed helper.";
      };
    };
  };

  config = mkMerge [
    (mkIf cfg.enable (
      let
        loadCredentials = (map (entry: entry.credentialName + ":" + toString entry.passwordFile) userEntries)
          ++ lib.optional (cfg.dashboard.enable && cfg.dashboard.passwordFile != null) (
          "dashboard_password:" + toString cfg.dashboard.passwordFile
        );
        credentialDir = "/run/credentials/${serviceUnit}";
        usersSpecFile = pkgs.writeText "emqx-users.json" (builtins.toJSON (map
          (entry: {
            user_id = entry.username;
            credential = entry.credentialName;
            tags = entry.tags;
          })
          userEntries));
        userSyncScript = pkgs.writeShellScript "emqx-sync-users" ''
          set -euo pipefail

          export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.curl pkgs.jq pkgs.util-linux pkgs.podman ]}
          specs_file=${lib.escapeShellArg usersSpecFile}
          credential_dir=${lib.escapeShellArg credentialDir}
          api_base=${lib.escapeShellArg "http://127.0.0.1:${toString cfg.dashboard.port}/api/v5"}
          authenticator_id='password_based%3Abuilt_in_database'
          dashboard_user=${lib.escapeShellArg cfg.dashboard.username}
          dashboard_credential_file="$credential_dir/dashboard_password"
          container_name=${lib.escapeShellArg serviceName}

          get_netns() {
            podman inspect "$container_name" --format '{{.NetworkSettings.SandboxKey}}' 2>/dev/null | tr -d '\r'
          }

          if [ ! -s "$specs_file" ] || ! jq -e 'length > 0' "$specs_file" >/dev/null 2>&1; then
            exit 0
          fi

          if [ ! -f "$dashboard_credential_file" ]; then
            echo "EMQX dashboard credential is missing; cannot sync MQTT users" >&2
            exit 1
          fi

          dashboard_password="$(cat "$dashboard_credential_file")"
          login_payload="$(jq -n --arg username "$dashboard_user" --arg password "$dashboard_password" '{username:$username,password:$password}')"

          netns_path=""
          for attempt in $(seq 1 90); do
            netns_path="$(get_netns)"
            if [ -n "$netns_path" ] && [ -e "$netns_path" ]; then
              break
            fi
            sleep 1
          done

          if [ -z "$netns_path" ] || [ ! -e "$netns_path" ]; then
            echo "Failed to resolve EMQX network namespace" >&2
            exit 1
          fi

          perform_request() {
            nsenter --net="$netns_path" -- curl -sS "$@"
          }

          token=""
          for attempt in $(seq 1 90); do
            if login_response="$(perform_request -H 'Content-Type: application/json' -d "$login_payload" -X POST "$api_base/login" 2>/dev/null)"; then
              token="$(printf '%s' "$login_response" | jq -r '.token // empty')"
              if [ -n "$token" ]; then
                break
              fi
            fi
            sleep 2
          done

          if [ -z "$token" ]; then
            echo "Failed to obtain EMQX API token after waiting" >&2
            exit 1
          fi

          tmp_response="$(mktemp)"
          trap 'rm -f "$tmp_response"' EXIT

          jq -c '.[]' "$specs_file" | while read -r spec; do
            user_id="$(printf '%s' "$spec" | jq -r '.user_id')"
            credential_name="$(printf '%s' "$spec" | jq -r '.credential')"
            password="$(cat "$credential_dir/$credential_name")"
            payload="$(jq -n \
              --arg user_id "$user_id" \
              --arg password "$password" \
              '({user_id:$user_id,password:$password}) | .is_superuser = false')"
            encoded_user_id="$(jq -rn --arg value "$user_id" '$value|@uri')"

            status="$(perform_request -o "$tmp_response" -w '%{http_code}' \
              -X PUT \
              -H "Authorization: Bearer $token" \
              -H 'Content-Type: application/json' \
              -d "$payload" \
              "$api_base/authentication/$authenticator_id/users/$encoded_user_id" || true)"

            case "$status" in
              200|201|204)
                ;;
              *)
                status="$(perform_request -o "$tmp_response" -w '%{http_code}' \
                  -X POST \
                  -H "Authorization: Bearer $token" \
                  -H 'Content-Type: application/json' \
                  -d "$payload" \
                  "$api_base/authentication/$authenticator_id/users" || true)"
                case "$status" in
                  200|201|204|409)
                    # 409 indicates the user already exists; treat as success
                    ;;
                  *)
                    echo "Failed to sync EMQX user '$user_id' (status $status)" >&2
                    cat "$tmp_response" >&2
                    exit 1
                    ;;
                esac
                ;;
            esac
          done
        '';

      in
      {
        assertions = [
          {
            assertion = cfg.allowAnonymous || allUsers != [ ];
            message = "modules.services.emqx.users must contain at least one user when allowAnonymous = false.";
          }
          {
            assertion = !(cfg.dashboard.enable && cfg.dashboard.passwordFile == null);
            message = "modules.services.emqx.dashboard.passwordFile is required when the dashboard is enabled.";
          }
        ];

        users.users.${cfg.user} = {
          isSystemUser = true;
          group = cfg.group;
          description = "EMQX broker account";
        };
        users.groups.${cfg.group} = { };

        systemd.tmpfiles.rules =
          [
            "d ${cfg.dataDir} 0750 ${cfg.user} ${cfg.group} -"
          ];

        modules.storage.datasets.services.${serviceName} = {
          mountpoint = cfg.dataDir;
          recordsize = "128K";
          compression = "zstd";
          owner = cfg.user;
          group = cfg.group;
          mode = "0750";
        };

        virtualisation.oci-containers.containers.${serviceName} = podmanLib.mkContainer serviceName {
          image = cfg.image;
          environmentFiles = [ envFile ];
          user = "0";
          volumes = [
            "${cfg.dataDir}:/opt/emqx/data:rw"
          ];
          ports =
            [
              "${cfg.listeners.mqtt.host}:${toString cfg.listeners.mqtt.port}:1883/tcp"
            ]
            ++ lib.optionals cfg.listeners.websocket.enable [
              "${cfg.listeners.websocket.host}:${toString cfg.listeners.websocket.port}:8083/tcp"
            ]
            ++ lib.optionals cfg.dashboard.enable [
              "${cfg.dashboard.listenAddress}:${toString cfg.dashboard.port}:18083/tcp"
            ];
          resources = cfg.resources;
          extraOptions = [ "--pull=newer" ]
            ++ lib.optionals (cfg.podmanNetwork != null) [ "--network=${cfg.podmanNetwork}" ]
            ++ lib.optionals (cfg.healthcheck != null && cfg.healthcheck.enable) [
            "--health-cmd=bash -c 'echo > /dev/tcp/127.0.0.1/1883' || exit 1"
            "--health-interval=${cfg.healthcheck.interval}"
            "--health-timeout=${cfg.healthcheck.timeout}"
            "--health-retries=${toString cfg.healthcheck.retries}"
            "--health-start-period=${cfg.healthcheck.startPeriod}"
          ];
        };

        systemd.services.${serviceAttrName} = {
          after = [ "network-online.target" envfileServiceUnit ] ++ lib.optionals cfg.preseed.enable [ "emqx-preseed.service" ];
          wants = [ "network-online.target" envfileServiceUnit ] ++ lib.optionals cfg.preseed.enable [ "emqx-preseed.service" ];
          requires = [ envfileServiceUnit ];
          serviceConfig =
            {
              LoadCredential = loadCredentials;
            }
            // lib.optionalAttrs (cfg.dashboard.enable && allUsers != [ ]) {
              ExecStartPost = lib.mkAfter [ "${userSyncScript}" ];
            };
          unitConfig = lib.mkIf (hasCentralizedNotifications && cfg.notifications != null && cfg.notifications.enable) {
            OnFailure = [ "notify@emqx-failure:%n.service" ];
          };
        };

        systemd.services.${envfileServiceAttrName} = {
          description = "Generate environment metadata for ${serviceName} container";
          startLimitIntervalSec = 0;
          startLimitBurst = 0;
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = false;
          };
          script = ''
                        set -euo pipefail
                        install -d -m 700 ${envDir}
                        tmp="${envFile}.tmp"
                        trap 'rm -f "$tmp"' EXIT
                        {
                          printf "TZ=%s\n" ${lib.escapeShellArg cfg.timezone}
                          printf "EMQX_NODE__NAME=%s\n" ${lib.escapeShellArg cfg.nodeName}
                          printf "EMQX_NODE__COOKIE=%s\n" ${lib.escapeShellArg cfg.nodeCookie}
                          printf "EMQX_LISTENERS__TCP__DEFAULT__ENABLE=%s\n" false
                          printf "EMQX_LISTENERS__TCP__EXTERNAL__BIND=%s:%s\n" ${lib.escapeShellArg cfg.listeners.mqtt.host} ${lib.escapeShellArg (toString cfg.listeners.mqtt.port)}
                          printf "EMQX_LISTENERS__TCP__EXTERNAL__MAX_CONNECTIONS=%s\n" ${lib.escapeShellArg (toString cfg.listeners.mqtt.maxConnections)}
                          printf "EMQX_ALLOW_ANONYMOUS=%s\n" ${lib.escapeShellArg (boolString cfg.allowAnonymous)}
                          printf "EMQX_AUTHENTICATION__1__ENABLE=%s\n" true
                          printf "EMQX_AUTHENTICATION__1__MECHANISM=%s\n" password_based
                          printf "EMQX_AUTHENTICATION__1__BACKEND=%s\n" built_in_database
                          ${lib.optionalString cfg.listeners.websocket.enable ''
                            printf "EMQX_LISTENERS__WS__EXTERNAL__BIND=%s:%s\n" ${lib.escapeShellArg cfg.listeners.websocket.host} ${lib.escapeShellArg (toString cfg.listeners.websocket.port)}
                            printf "EMQX_LISTENERS__WS__EXTERNAL__ENABLE=%s\n" true
                          ''}
                          ${lib.optionalString cfg.dashboard.enable ''
                            printf "EMQX_DASHBOARD__LISTENERS__HTTP__BIND=%s:%s\n" ${lib.escapeShellArg dashboardContainerBindAddress} ${lib.escapeShellArg (toString cfg.dashboard.port)}
                            printf "EMQX_DASHBOARD__DEFAULT_USERNAME=%s\n" ${lib.escapeShellArg cfg.dashboard.username}
                            printf "EMQX_DASHBOARD__DEFAULT_PASSWORD=%s\n" "$(cat ${lib.escapeShellArg (toString cfg.dashboard.passwordFile)})"
                          ''}
                          ${lib.optionalString authorizationEnabled ''
                            printf "EMQX_AUTHORIZATION__ENABLE=%s\n" true
                            printf "EMQX_AUTHORIZATION__NO_MATCH=%s\n" ${lib.escapeShellArg cfg.authorization.noMatch}
                            printf "EMQX_AUTHORIZATION__SOURCES__1__TYPE=%s\n" file
                            printf "EMQX_AUTHORIZATION__SOURCES__1__ENABLE=%s\n" true
                            printf "EMQX_AUTHORIZATION__SOURCES__1__PATH=%s\n" /opt/emqx/data/authz.conf
                          ''}
                        } > "$tmp"
                        install -m 600 "$tmp" ${envFile}
                        ${lib.optionalString authorizationEnabled ''
                          cat <<'ACL' > ${aclFile}
            %% Autogenerated by nix-config (modules.services.emqx)
            ${aclFileContents}
            ACL
                          chown ${cfg.user}:${cfg.group} ${aclFile}
                          chmod 640 ${aclFile}
                        ''}
          '';
        };

        modules.notifications.templates = lib.mkIf (hasCentralizedNotifications && cfg.notifications != null && cfg.notifications.enable) {
          "emqx-failure" = {
            enable = true;
            priority = "high";
            title = "❌ EMQX broker failed";
            body = ''
              <b>Host:</b> ${config.networking.hostName}
              <b>Service:</b> ${serviceUnit}

              Check logs: <code>journalctl -u ${serviceUnit} -n 200</code>
            '';
          };
        };

        modules.backup.restic.jobs = lib.mkIf (cfg.backup != null && cfg.backup.enable) {
          emqx = {
            enable = true;
            repository = cfg.backup.repository;
            frequency = cfg.backup.frequency;
            retention = cfg.backup.retention;
            paths = if cfg.backup.paths != [ ] then cfg.backup.paths else [ cfg.dataDir ];
            excludePatterns = cfg.backup.excludePatterns;
            useSnapshots = cfg.backup.useSnapshots or true;
            zfsDataset = cfg.backup.zfsDataset or datasetPath;
            tags = cfg.backup.tags;
          };
        };

        modules.services.caddy.virtualHosts."${serviceName}-dashboard" = mkIf (cfg.dashboard.enable && cfg.dashboard.reverseProxy != null && cfg.dashboard.reverseProxy.enable) (
          let
            defaultBackend = {
              scheme = "http";
              host = cfg.dashboard.listenAddress;
              port = cfg.dashboard.port;
            };
            configuredBackend = cfg.dashboard.reverseProxy.backend or { };
          in
          {
            enable = true;
            hostName = cfg.dashboard.reverseProxy.hostName;
            backend = lib.recursiveUpdate defaultBackend configuredBackend;
            auth = cfg.dashboard.reverseProxy.auth;
            security = cfg.dashboard.reverseProxy.security;
            extraConfig = cfg.dashboard.reverseProxy.extraConfig;
          }
        );

        # NOTE: Service alerts are defined at host level (e.g., hosts/forge/services/emqx.nix)
        # to keep modules portable and not assume Prometheus availability
      }
    ))

    (mkIf (cfg.enable && cfg.preseed.enable) (
      storageHelpers.mkPreseedService {
        serviceName = serviceName;
        dataset = datasetPath;
        mountpoint = cfg.dataDir;
        mainServiceUnit = serviceUnit;
        replicationCfg = null;
        datasetProperties = {
          recordsize = "128K";
          compression = "zstd";
          "com.sun:auto-snapshot" = "true";
        };
        resticRepoUrl = cfg.preseed.repositoryUrl;
        resticPasswordFile = cfg.preseed.passwordFile;
        resticEnvironmentFile = cfg.preseed.environmentFile;
        resticPaths = [ cfg.dataDir ];
        restoreMethods = cfg.preseed.restoreMethods;
        hasCentralizedNotifications = hasCentralizedNotifications;
        owner = cfg.user;
        group = cfg.group;
      }
    ))
  ];
}
