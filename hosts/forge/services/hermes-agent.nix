# hosts/forge/services/hermes-agent.nix
#
# Hermes runs natively through its upstream NixOS module. Native mode keeps
# the runtime immutable and applies systemd hardening to every spawned tool;
# upstream container mode intentionally uses a mutable, host-networked runtime.

{ config, inputs, lib, mylib, pkgs, ... }:

let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  serviceName = "hermes-agent";
  stateDir = "/var/lib/hermes";
  dataset = "tank/services/${serviceName}";
  serviceIds = mylib.serviceUids.hermes;
  serviceEnabled = config.services.hermes-agent.enable or false;
  hermesPackage = inputs.hermes-agent.packages.${pkgs.stdenv.hostPlatform.system}.default;
  householdAdvisorPrompt = ''
    You are Household Advisor. Be concise, factual, and family-appropriate.
    You do not currently have access to household financial data. If a request
    needs the pending homelab-mcp finances tools, say that you do not have data
    access yet; never infer, estimate, or invent values.
    Never provide investment advice. For financial questions beyond simple
    facts, say: "bring it to the monthly review."
  '';
  hermesCli = pkgs.writeShellScriptBin "hermes" ''
    export HOME="${stateDir}"
    export HERMES_HOME="${stateDir}/.hermes"
    cd "${stateDir}/workspace"
    exec ${hermesPackage}/bin/hermes "$@"
  '';
in
{
  imports = [
    inputs.hermes-agent.nixosModules.default
  ];

  config = lib.mkMerge [
    {
      services.hermes-agent = {
        enable = true;
        package = hermesPackage;

        user = "hermes";
        group = "hermes";
        createUser = false;
        inherit stateDir;
        workingDirectory = "${stateDir}/workspace";

        # A small wrapper below exposes the managed CLI without merging the
        # upstream package's unstable propagated tools into the system profile.
        addToSystemPackages = false;
        environmentFiles = [
          config.sops.templates."hermes-agent-env".path
          config.sops.secrets."hermes-agent/signal-env".path
        ];
        environment = {
          API_SERVER_ENABLED = "false";
          # Telegram numeric IDs are stable and non-secret. Keep the env
          # allowlist as defense in depth alongside the platform policy below.
          TELEGRAM_ALLOWED_USERS = "8903896206";
        };

        mcpServers.holthome = {
          url = "https://mcp.${config.networking.domain}/mcp";
          auth = "oauth";
          connect_timeout = 60;
          timeout = 120;
          tools.include = [
            "cooklang_list_recipes"
            "cooklang_get_recipe"
            "cooklang_search_federation"
            "cooklang_build_shopping_list"

            "homelab_list_status"
            "homelab_get_endpoint_history"

            "grocy_health"
            "grocy_find_products"
            "grocy_attention"
            "grocy_convert_units"
            "grocy_product_card"
            "grocy_consumption_history"
            "grocy_stock_value"
            "grocy_stock_by_location"

            "ha_health"
            "ha_list_entities"
            "ha_get_state"
            "ha_get_history"
            "ha_list_automations"
            "ha_get_automation"
            "ha_check_config"

            "arc_search_items"
            "arc_search_quests"
            "arc_get_trader_stock"
            "arc_check_item_keep"
            "arc_plan_upgrades"
            "arc_get_enemy"
            "arc_who_drops"
            "arc_compare_weapons"
            "arc_list_raids"
            "arc_raid_stats"
            "arc_get_state"
            "arc_patch_diff"
            "arc_get_event_schedule"
            "arc_list_maps"
            "arc_search_wiki"
            "arc_get_wiki_page"
          ];
          sampling.enabled = false;
        };

        settings = {
          _config_version = 33;
          model.default = "anthropic/claude-sonnet-4";
          timezone = config.time.timeZone;
          platform_toolsets.cron = [ "safe" "holthome" ];
          gateway.platforms.telegram = {
            enabled = true;
            dm_policy = "allowlist";
            allow_from = [ "8903896206" ];
            # A user's private Telegram chat ID equals their numeric user ID.
            allowed_chats = [ "8903896206" ];
            group_policy = "disabled";
          };
          gateway.platforms.signal = {
            enabled = true;
            # SIGNAL_ALLOWED_USERS is mirrored into the SOPS env. An explicit
            # allowlist makes unauthorized DMs silent instead of issuing
            # pairing codes; group intake is separately restricted by
            # SIGNAL_GROUP_ALLOWED_USERS.
            channel_overrides."+12406206585".system_prompt = householdAdvisorPrompt;
          };
          terminal = {
            backend = "local";
            timeout = 180;
          };
          tool_loop_guardrails = {
            hard_stop_enabled = true;
            hard_stop_after = {
              exact_failure = 5;
              idempotent_no_progress = 5;
            };
          };
        };

        restartSec = 10;
      };

      environment.systemPackages = [ hermesCli ];

      users.groups.hermes.gid = serviceIds.gid;
      users.users.hermes = {
        uid = serviceIds.uid;
        isSystemUser = true;
        group = "hermes";
        description = serviceIds.description;
        home = stateDir;
        createHome = true;
        shell = pkgs.bashInteractive;
        extraGroups = serviceIds.extraGroups;
      };

      # Repair ownership from the initial deployment, which briefly used a UID
      # already assigned to nscd. The mode field is "-" to preserve restrictive
      # runtime file permissions while recursively fixing only owner/group.
      systemd.tmpfiles.rules = [
        "Z ${stateDir} - hermes hermes -"
      ];
    }

    (lib.mkIf serviceEnabled {
      modules.storage.datasets.services.${serviceName} = {
        mountpoint = stateDir;
        recordsize = "16K";
        compression = "zstd";
        properties = {
          atime = "off";
          "com.sun:auto-snapshot" = "true";
        };
        owner = "hermes";
        group = "hermes";
        mode = "0750";
      };

      modules.backup.sanoid.datasets.${dataset} =
        forgeDefaults.mkSanoidDataset serviceName;

      modules.services.backup.restic.jobs.${serviceName} = {
        enable = true;
        repository = forgeDefaults.backup.repository;
        paths = [ stateDir ];
        tags = [ serviceName "ai" "forge" ];
        frequency = "daily";
        useSnapshots = true;
        zfsDataset = dataset;
      };

      modules.alerting.rules."${serviceName}-service-down" =
        forgeDefaults.mkSystemdServiceDownAlert
          serviceName
          "Hermes Agent"
          "AI agent gateway";

      # The upstream native unit already uses NoNewPrivileges,
      # ProtectSystem=strict, PrivateTmp, and a dedicated user. Tighten the
      # remaining host boundary and cap runaway agent resource consumption.
      systemd.services.hermes-agent = {
        # Keep Hermes running across signal-api restarts so its WebSocket loop
        # can reconnect with the adapter's jittered 2s -> 60s backoff.
        after = [ "podman-signal-api.service" ];
        wants = [ "podman-signal-api.service" ];

        # Hermes expands env references only in YAML values, not mapping keys.
        # Render the SOPS-held group ID into the exact Signal chat key before
        # startup, then wait for the REST API so the initial connect is not
        # lost while the json-rpc daemon is still warming up.
        preStart = ''
          signalGroupId="$(${pkgs.gawk}/bin/awk -F= '
            $1 == "SIGNAL_GROUP_ALLOWED_USERS" {
              sub(/^[^=]*=/, "")
              value = $0
            }
            END {
              if (value == "") exit 1
              print value
            }
          ' "${stateDir}/.hermes/.env")"

          case "$signalGroupId" in
            group.*)
              echo "hermes-agent: Signal inbound group ID must not include the REST send prefix" >&2
              exit 1
              ;;
            ?*) ;;
            *)
              echo "hermes-agent: Signal inbound group ID is missing" >&2
              exit 1
              ;;
          esac

          SIGNAL_GROUP_CHAT_ID="group:$signalGroupId" \
          HOUSEHOLD_ADVISOR_PROMPT="$(${pkgs.coreutils}/bin/cat ${pkgs.writeText "household-advisor-prompt" householdAdvisorPrompt})" \
            ${pkgs.yq-go}/bin/yq --inplace \
              '.gateway.platforms.signal.channel_overrides |= with_entries(select(.key | test("^group:") | not)) |
               .gateway.platforms.signal.channel_overrides[strenv(SIGNAL_GROUP_CHAT_ID)].system_prompt = strenv(HOUSEHOLD_ADVISOR_PROMPT)' \
              "${stateDir}/.hermes/config.yaml"

          ${pkgs.curl}/bin/curl --fail --silent --show-error \
            --retry 30 --retry-all-errors --retry-delay 2 \
            --connect-timeout 2 --max-time 5 \
            "http://127.0.0.1:${toString config.modules.services.signal-api.port}/v1/health" \
            --output /dev/null
        '';

        # Upstream merges config.yaml during activation, outside the unit, so
        # settings changes otherwise leave the running gateway on stale config.
        restartTriggers = [
          (pkgs.writeText "hermes-agent-settings" (builtins.toJSON config.services.hermes-agent.settings))
        ];

        serviceConfig = {
          ProtectHome = lib.mkForce true;
          PrivateDevices = true;
          ProtectClock = true;
          ProtectControlGroups = true;
          ProtectKernelLogs = true;
          ProtectKernelModules = true;
          ProtectKernelTunables = true;
          RestrictSUIDSGID = true;
          LockPersonality = true;
          RestrictRealtime = true;
          SystemCallArchitectures = "native";
          CapabilityBoundingSet = "";
          AmbientCapabilities = "";
          UMask = lib.mkForce "0077";
          MemoryHigh = "3G";
          MemoryMax = "4G";
          CPUQuota = "200%";
          TasksMax = 512;
        };
      };
    })
  ];
}
