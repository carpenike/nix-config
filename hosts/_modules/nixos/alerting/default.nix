# hosts/_modules/nixos/alerting/default.nix
{ lib, config, pkgs, ... }:

let
  inherit (lib) mkOption types mkIf length;

  cfg = config.modules.alerting;

  # Helper: severity enumeration
  severityEnum = types.enum [ "critical" "high" "medium" "low" ];

  # Submodule defining a single alert rule
  ruleSubmodule = types.submodule {
    options = {
      type = mkOption {
        type = types.enum [ "event" "promql" ];
        default = "event";
        description = "Alert type: direct event injection or PromQL rule.";
      };

      alertname = mkOption {
        type = types.str;
        description = "Alertname label for the alert.";
      };

      severity = mkOption {
        type = severityEnum;
        default = "medium";
        description = "Alert severity used for Alertmanager routing.";
      };

      labels = mkOption {
        type = types.attrsOf types.str;
        default = {};
        description = "Additional labels (e.g., { service = \"sonarr\"; category = \"systemd\"; }).";
      };

      annotations = mkOption {
        type = types.attrsOf types.str;
        default = {};
        description = "Annotations for title/body (e.g., { title = \"...\"; body = \"...\"; }).";
      };

      # For type = "event": optional automated OnFailure attachment
      systemd = mkOption {
        type = types.submodule {
          options = {
            unit = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "Target systemd unit (e.g., \"sonarr.service\") for OnFailure wiring.";
            };
            onFailure.enable = mkOption {
              type = types.bool;
              default = false;
              description = "If true, attach OnFailure to the specified systemd unit.";
            };
          };
        };
        default = {};
        description = "Systemd-specific configuration for event rules.";
      };

      # For type = "promql": expression and duration
      expr = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "PromQL expression (required when type = \"promql\").";
      };
      for = mkOption {
        type = types.str;
        default = "0s";
        description = "Required time for a PromQL alert to be active before firing.";
      };
    };
  };

  # Helper script to post an alert to Alertmanager (robust retries, no secrets in store)
  amPost = pkgs.writeShellScriptBin "am-postalert" ''
    set -euo pipefail
    AM_URL="''${1:?}"          # e.g., http://127.0.0.1:9093
    ALERTNAME="''${2:?}"       # e.g., systemd_unit_failed
    SEVERITY="''${3:?}"        # e.g., high
    SERVICE="''${4:?}"         # e.g., sonarr
    TITLE="''${5:?}"           # e.g., "Sonarr Failed"
    BODY="''${6:?}"            # e.g., "Service %n failed on forge"
    UNIT="''${7:-}"            # e.g., "sonarr.service"
    INSTANCE="$(hostname -f 2>/dev/null || hostname)"

    # Build payload using jq for safe JSON construction
    payload="$(${pkgs.jq}/bin/jq -n \
      --arg alertname "''${ALERTNAME}" \
      --arg severity "''${SEVERITY}" \
      --arg service "''${SERVICE}" \
      --arg instance "''${INSTANCE}" \
      --arg title "''${TITLE}" \
      --arg body "''${BODY}" \
      --arg unit "''${UNIT}" \
      '[{
        labels: {
          alertname: $alertname,
          severity: $severity,
          service: $service,
          instance: $instance
        } + (if $unit != "" then {unit: $unit} else {} end),
        annotations: {
          summary: $title,
          description: $body
        }
      }]')"

    attempt=0
    max_attempts=3
    while [ "''${attempt}" -lt "''${max_attempts}" ]; do
      if curl --fail --silent --show-error -X POST \
        -H 'Content-Type: application/json' \
        --data "''${payload}" \
        "''${AM_URL}/api/v2/alerts"; then
        exit 0
      fi
      attempt=$((attempt+1))
      sleep 2
    done
    echo "am-postalert: failed to POST to Alertmanager after ''${max_attempts} attempts" >&2
    exit 1
  '';

  # Alertmanager config template (no secrets baked in; rendered at runtime)
  amTmpl = pkgs.writeText "alertmanager.tmpl.yml" ''
route:
  group_by: ['alertname','service']
  group_wait: 0s
  group_interval: 1m
  repeat_interval: 2h
  routes:
    - matchers:
        - severity="critical"
      receiver: 'pushover-critical'
      group_wait: 0s
      repeat_interval: 15m
    - matchers:
        - severity="high"
      receiver: 'pushover-high'
      group_wait: 0s
      repeat_interval: 30m
    - matchers:
        - severity="medium"
      receiver: 'pushover-medium'
    - matchers:
        - severity="low"
      receiver: 'pushover-low'

receivers:
  - name: pushover-critical
    pushover_configs:
      - token: "__PUSHOVER_TOKEN__"
        user_key: "__PUSHOVER_USER__"
        priority: 2
        title: '{{ index .Annotations "summary" }}'
        message: '{{ index .Annotations "description" }}'
  - name: pushover-high
    pushover_configs:
      - token: "__PUSHOVER_TOKEN__"
        user_key: "__PUSHOVER_USER__"
        priority: 1
        title: '{{ index .Annotations "summary" }}'
        message: '{{ index .Annotations "description" }}'
  - name: pushover-medium
    pushover_configs:
      - token: "__PUSHOVER_TOKEN__"
        user_key: "__PUSHOVER_USER__"
        priority: 0
        title: '{{ index .Annotations "summary" }}'
        message: '{{ index .Annotations "description" }}'
  - name: pushover-low
    pushover_configs:
      - token: "__PUSHOVER_TOKEN__"
        user_key: "__PUSHOVER_USER__"
        priority: -1
        title: '{{ index .Annotations "summary" }}'
        message: '{{ index .Annotations "description" }}'
  '';

in
{
  options.modules.alerting = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = "Enable the alerting module.";
    };

    alertmanager.url = mkOption {
      type = types.str;
      default = "http://127.0.0.1:9093";
      description = "Alertmanager base URL used by am-postalert.";
    };

    receivers.pushover.tokenSecret = mkOption {
      type = types.str;
      default = "pushover_token";
      description = "SOPS secret name that contains the Pushover API token.";
    };

    receivers.pushover.userSecret = mkOption {
      type = types.str;
      default = "pushover_user";
      description = "SOPS secret name that contains the Pushover user key.";
    };

    rules = mkOption {
      type = types.attrsOf ruleSubmodule;
      default = {};
      description = "Alert rules keyed by rule ID (e.g., \"sonarr-failure\").";
    };

  };

  config = mkIf cfg.enable {
    # Assertions for rule correctness to keep things type-safe
    assertions =
      let ruleNames = builtins.attrNames (cfg.rules or {});
      in
      # PromQL rules must have expr set
      (map (r:
        { assertion = (cfg.rules.${r}.type != "promql") || (cfg.rules.${r}.expr != null);
          message = "modules.alerting.rules.${r}: PromQL rule must set 'expr'.";
        }
      ) ruleNames)
      ++
      # Event rules typically should set alertname
      (map (r:
        { assertion = (cfg.rules.${r}.alertname != "");
          message = "modules.alerting.rules.${r}: 'alertname' must not be empty.";
        }
      ) ruleNames);

    # Render Alertmanager config with secrets at runtime
    # Runs as root to read root-owned SOPS secrets, then chowns output to alertmanager
    systemd.services.alertmanager-config = {
      description = "Render Alertmanager config with secrets";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = ''
          install -d -m 0750 -o alertmanager -g alertmanager /etc/alertmanager
          token="$(cat ${config.sops.secrets.${cfg.receivers.pushover.tokenSecret}.path})"
          user="$(cat ${config.sops.secrets.${cfg.receivers.pushover.userSecret}.path})"
          sed -e "s/__PUSHOVER_TOKEN__/${lib.escapeShellArg "$token"}/g" \
              -e "s/__PUSHOVER_USER__/${lib.escapeShellArg "$user"}/g" \
              ${amTmpl} > /etc/alertmanager/alertmanager.yml
          chown alertmanager:alertmanager /etc/alertmanager/alertmanager.yml
          chmod 0640 /etc/alertmanager/alertmanager.yml
        '';
      };
    };

    # Alertmanager service ordering and flags
    services.prometheus.alertmanager = {
      enable = true;
      # Placeholder config - actual config loaded from /etc/alertmanager/alertmanager.yml
      configuration = {
        route = {
          receiver = "pushover-medium";
          group_by = [ "alertname" ];
        };
        receivers = [
          { name = "pushover-medium"; }
        ];
      };
      extraFlags = [ "--config.file=/etc/alertmanager/alertmanager.yml" ];
    };
    systemd.services.prometheus-alertmanager = {
      wants = [ "alertmanager-config.service" ];
      after = [ "alertmanager-config.service" ];
    };

    # Boot and shutdown system events
    systemd.services = {
        alert-boot = {
          description = "Send boot event to Alertmanager";
          wantedBy = [ "multi-user.target" ];
          wants = [ "network-online.target" ];
          after = [ "network-online.target" "prometheus-alertmanager.service" ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = ''
              ${amPost}/bin/am-postalert \
                ${cfg.alertmanager.url} \
                system_boot \
                low \
                "system" \
                "Host ${config.networking.hostName} booted" \
                "System boot on ${config.networking.hostName}" \
                ""
            '';
          };
        };

      alert-shutdown = {
        description = "Send shutdown event to Alertmanager";
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "simple";
          ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
          ExecStopPost = ''
            ${amPost}/bin/am-postalert \
              ${cfg.alertmanager.url} \
              system_shutdown_requested \
              low \
              "system" \
              "Host ${config.networking.hostName} shutdown requested" \
              "System shutdown on ${config.networking.hostName}" \
              ""
          '';
        };
      };
    };
  };
}
