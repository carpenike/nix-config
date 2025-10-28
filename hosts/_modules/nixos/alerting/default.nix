# hosts/_modules/nixos/alerting/default.nix
{ lib, config, pkgs, ... }:

let
  inherit (lib) mkOption types mkIf filterAttrs mapAttrsToList;

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
    PATH="${lib.makeBinPath [ pkgs.coreutils pkgs.inetutils pkgs.curl pkgs.jq ]}"
    AM_URL="''${1:?}"          # e.g., http://127.0.0.1:9093
    ALERTNAME="''${2:?}"       # e.g., systemd_unit_failed
    SEVERITY="''${3:?}"        # e.g., high
    SERVICE="''${4:?}"         # e.g., sonarr
    TITLE="''${5:?}"           # e.g., "Sonarr Failed"
    BODY="''${6:?}"            # e.g., "Service %n failed on forge"
    UNIT="''${7:-}"            # e.g., "sonarr.service"
    INSTANCE="$(hostname -f 2>/dev/null || hostname)"

    # Build payload using jq for safe JSON construction (conditionally include unit label)
    payload="$(${pkgs.jq}/bin/jq -n \
      --arg alertname "''${ALERTNAME}" \
      --arg severity "''${SEVERITY}" \
      --arg service "''${SERVICE}" \
      --arg instance "''${INSTANCE}" \
      --arg title "''${TITLE}" \
      --arg body "''${BODY}" \
      --arg unit "''${UNIT}" \
      '[{
        labels: ( { alertname: $alertname, severity: $severity, service: $service, instance: $instance }
                  + (if $unit != "" then { unit: $unit } else {} end) ),
        annotations: { summary: $title, description: $body }
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

in
{
  options.modules.alerting = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable the alerting module.";
    };

    alertmanager.url = mkOption {
      type = types.str;
      default = "http://127.0.0.1:9093";
      description = "Alertmanager base URL used by am-postalert.";
    };

    alertmanager.externalUrl = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "External URL for Alertmanager (used in alert links). If null, uses alertmanager.url.";
    };

    prometheus.externalUrl = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "External URL for Prometheus (used in alert links and UI). Example: https://prometheus.example.com";
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

    receivers.healthchecks.urlSecret = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "SOPS secret name that contains the Healthchecks.io (or similar) webhook URL for dead man's switch.";
    };

    rules = mkOption {
      type = types.attrsOf ruleSubmodule;
      default = {};
      description = "Alert rules keyed by rule ID (e.g., \"sonarr-failure\").";
    };

    prometheus.ruleFilePath = mkOption {
      type = types.path;
      readOnly = true;
      description = "Path to the generated Prometheus alert rules file.";
    };

  };

  config = mkIf cfg.enable (let
    # Move promqlRules and prometheusRuleFile computation inside config block
    # to avoid infinite recursion when referencing cfg.rules
    promqlRules = filterAttrs (_: rule: rule.type == "promql") cfg.rules;

    prometheusRuleFile = pkgs.writeText "prometheus-alert-rules.yml" (
      lib.generators.toYAML {} {
        groups = [{
          name = "homelab-alerts";
          interval = "15s";
          rules = mapAttrsToList (name: rule: {
            alert = rule.alertname;
            expr = rule.expr;
            for = rule.for;
            labels = rule.labels // {
              severity = rule.severity;
              alertname = rule.alertname;
            };
            annotations = rule.annotations // {
              summary = rule.annotations.summary or "Alert ${rule.alertname} fired";
              description = rule.annotations.description or "Alert ${rule.alertname} requires attention";
            };
          }) promqlRules;
        }];
      }
    );
  in {
    # Expose the generated Prometheus rule file path
    modules.alerting.prometheus.ruleFilePath = prometheusRuleFile;
    # Assertions for rule correctness to keep things type-safe
    assertions =
      let ruleNames = builtins.attrNames (cfg.rules or {});
      in
      [
        # Pushover secrets must exist when alerting is enabled
        {
          assertion = builtins.hasAttr cfg.receivers.pushover.tokenSecret config.sops.secrets;
          message = "modules.alerting: Pushover token secret '${cfg.receivers.pushover.tokenSecret}' not found in sops.secrets. Either define the secret or disable alerting.";
        }
        {
          assertion = builtins.hasAttr cfg.receivers.pushover.userSecret config.sops.secrets;
          message = "modules.alerting: Pushover user secret '${cfg.receivers.pushover.userSecret}' not found in sops.secrets. Either define the secret or disable alerting.";
        }
      ]
      ++
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
      ) ruleNames)
      ++
      # Check for duplicate alertnames across all rules
      (let
        allAlertnames = builtins.filter (a: a != "") (map (r: cfg.rules.${r}.alertname) ruleNames);
        uniqueAlertnames = lib.unique allAlertnames;
        hasDuplicates = (builtins.length allAlertnames) != (builtins.length uniqueAlertnames);
        findDuplicates = names:
          let
            counts = lib.listToAttrs (map (name: { name = name; value = builtins.length (builtins.filter (n: n == name) names); }) (lib.unique names));
            duplicates = builtins.filter (name: counts.${name} > 1) (builtins.attrNames counts);
          in duplicates;
        duplicateList = if hasDuplicates then (builtins.concatStringsSep ", " (findDuplicates allAlertnames)) else "";
      in [{
        assertion = !hasDuplicates;
        message = "modules.alerting: Duplicate alertname labels found: ${duplicateList}. Each alert must have a unique alertname to avoid confusing grouping in Alertmanager.";
      }]);

    # Ensure alertmanager user/group exists before SOPS tries to install secrets
    users.users.alertmanager = {
      isSystemUser = true;
      group = "alertmanager";
    };
    users.groups.alertmanager = {};

    # Alertmanager configuration using native *_file pattern for secrets
    services.prometheus.alertmanager = {
      enable = true;
      configuration = {
        route = {
          receiver = "pushover-medium";
          # Group by instance (host) and alertname to avoid mixing unrelated alerts
          # This keeps host-wide failures consolidated while separating different alerts
          # into their own threads within the same host grouping.
          group_by = [ "instance" "alertname" ];
          # Wait 30s to catch other related alerts that may fire in quick succession
          group_wait = "30s";
          # Send updates for a group every 5 minutes if new alerts are added
          group_interval = "5m";
          # Default repeat interval for non-critical alerts
          repeat_interval = "4h";
          routes =
            # Prepend a route for the Dead Man's Switch to ensure it's handled first
            (lib.optional (cfg.receivers.healthchecks.urlSecret != null) {
              matchers = [ "alertname=\"Watchdog\"" ];
              receiver = "healthchecks-io";
              # Do not continue to other routes
              continue = false;
              # Send frequently to maintain heartbeat
              repeat_interval = "1m";
            })
            ++ [
            # Backup-specific grouping: group by host and repository for clarity
            {
              matchers = [ "category=\"restic\"" ];
              group_by = [ "hostname" "alertname" "repository" ];
              continue = true;
            }
            # Storage-specific grouping: treat each replication path as a distinct group
            {
              matchers = [ "category=~\"zfs|syncoid\"" ];
              group_by = [ "instance" "alertname" "dataset" "target_host" ];
              continue = true;  # Continue to severity-based delivery
            }
          ]
            ++ [
            {
              matchers = [ "severity=\"critical\"" ];
              receiver = "pushover-critical";
              # Repeat critical alerts more frequently to ensure they are not missed
              repeat_interval = "30m";
            }
            {
              matchers = [ "severity=\"high\"" ];
              receiver = "pushover-high";
              repeat_interval = "2h";
            }
            {
              matchers = [ "severity=\"medium\"" ];
              receiver = "pushover-medium";
              repeat_interval = "6h";
            }
            {
              matchers = [ "severity=\"low\"" ];
              receiver = "pushover-low";
              repeat_interval = "4h";
            }
          ];
        };

        # Inhibition rules to prevent redundant alerts
        # When a critical alert is active, suppress less severe related alerts
        inhibit_rules = [
          # Suppress replication noise when the target host is down
          # Requires an InstanceDown alert for the target host
          {
            target_matchers = [
              "alertname=~\"SyncoidReplicationFailed|SyncoidReplicationStale|ZFSReplicationLagHigh|ZFSReplicationStalled\""
            ];
            source_matchers = [
              "alertname=\"InstanceDown\""
            ];
            # Match target_host in the replication alert with instance in the InstanceDown alert
            equal = [ "target_host" "instance" ];
          }
          # Don't notify about being on battery if we already know the battery is low
          {
            target_matchers = [
              "severity=\"medium\""
              "alertname=\"UPSOnBattery\""
            ];
            source_matchers = [
              "severity=\"critical\""
              "alertname=\"UPSLowBattery\""
            ];
            # Only apply inhibition if alerts are for the same host
            equal = [ "instance" ];
          }
          # Don't notify about low battery charge if we have a critical runtime warning
          {
            target_matchers = [
              "severity=\"medium\""
              "alertname=\"UPSBatteryChargeLow\""
            ];
            source_matchers = [
              "severity=\"critical\""
              "alertname=\"UPSRuntimeCritical\""
            ];
            equal = [ "instance" ];
          }
          # Don't notify about scrape failures if the UPS is known to be offline
          {
            target_matchers = [
              "severity=\"high\""
              "alertname=\"UPSMetricsScrapeFailure\""
            ];
            source_matchers = [
              "severity=\"critical\""
              "alertname=\"UPSOffline\""
            ];
            equal = [ "instance" ];
          }
        ];
        receivers = [
          {
            name = "pushover-critical";
            pushover_configs = [{
              token_file = config.sops.secrets.${cfg.receivers.pushover.tokenSecret}.path;
              user_key_file = config.sops.secrets.${cfg.receivers.pushover.userSecret}.path;
              # Avoid Pushover "emergency" (priority=2) which retries every minute until ack
              # Use high priority (1) and send resolved notifications
              priority = 1;
              send_resolved = true;
              # Informative title: show group size when multiple alerts, else specific summary
              title = ''{{ if gt (len .Alerts) 1 }}[{{ len .Alerts }}] {{ .CommonLabels.alertname }} on {{ or .CommonLabels.instance .CommonLabels.hostname }}{{ else }}{{ if .CommonAnnotations.summary }}{{ .CommonAnnotations.summary }}{{ else }}{{ (index .Alerts 0).Annotations.summary }}{{ end }}{{ end }}'';
              # Message: list summaries for grouped alerts; else use description with fallback
              # Append runbook and command hints when provided by alert annotations
              message = ''{{ if gt (len .Alerts) 1 }}{{ range .Alerts }}- {{ .Annotations.summary }}
{{ end }}{{ else }}{{ if .CommonAnnotations.description }}{{ .CommonAnnotations.description }}{{ else }}{{ (index .Alerts 0).Annotations.description }}{{ end }}{{ end }}
{{ if .CommonAnnotations.runbook_url }}Runbook: {{ .CommonAnnotations.runbook_url }}{{ end }}
{{ if .CommonAnnotations.command }}Cmd: {{ .CommonAnnotations.command }}{{ end }}'';
              # Action link: pre-filled Silence form for this alert group (proper multi-filter params)
              url = ''{{ .ExternalURL }}/#/silences/new{{ range $i, $e := .CommonLabels.SortedPairs }}{{ if eq $i 0 }}?{{ else }}&{{ end }}filter={{ $e.Name }}%3D%22{{ $e.Value | urlquery }}%22{{ end }}'';
              url_title = ''Silence this Alert Group'';
              # Note: supplementary_urls not supported by current amtool config schema; omit for compatibility
            }];
          }
          {
            name = "pushover-high";
            pushover_configs = [{
              token_file = config.sops.secrets.${cfg.receivers.pushover.tokenSecret}.path;
              user_key_file = config.sops.secrets.${cfg.receivers.pushover.userSecret}.path;
              priority = 1;
              send_resolved = true;
              title = ''{{ if gt (len .Alerts) 1 }}[{{ len .Alerts }}] {{ .CommonLabels.alertname }} on {{ or .CommonLabels.instance .CommonLabels.hostname }}{{ else }}{{ if .CommonAnnotations.summary }}{{ .CommonAnnotations.summary }}{{ else }}{{ (index .Alerts 0).Annotations.summary }}{{ end }}{{ end }}'';
              message = ''{{ if gt (len .Alerts) 1 }}{{ range .Alerts }}- {{ .Annotations.summary }}
{{ end }}{{ else }}{{ if .CommonAnnotations.description }}{{ .CommonAnnotations.description }}{{ else }}{{ (index .Alerts 0).Annotations.description }}{{ end }}{{ end }}
{{ if .CommonAnnotations.runbook_url }}Runbook: {{ .CommonAnnotations.runbook_url }}{{ end }}
{{ if .CommonAnnotations.command }}Cmd: {{ .CommonAnnotations.command }}{{ end }}'';
              url = ''{{ .ExternalURL }}/#/silences/new{{ range $i, $e := .CommonLabels.SortedPairs }}{{ if eq $i 0 }}?{{ else }}&{{ end }}filter={{ $e.Name }}%3D%22{{ $e.Value | urlquery }}%22{{ end }}'';
              url_title = ''Silence this Alert Group'';
              # Note: supplementary_urls not supported by current amtool config schema; omit for compatibility
            }];
          }
          {
            name = "pushover-medium";
            pushover_configs = [{
              token_file = config.sops.secrets.${cfg.receivers.pushover.tokenSecret}.path;
              user_key_file = config.sops.secrets.${cfg.receivers.pushover.userSecret}.path;
              priority = 0;
              send_resolved = true;
              title = ''{{ if gt (len .Alerts) 1 }}[{{ len .Alerts }}] {{ .CommonLabels.alertname }} on {{ or .CommonLabels.instance .CommonLabels.hostname }}{{ else }}{{ if .CommonAnnotations.summary }}{{ .CommonAnnotations.summary }}{{ else }}{{ (index .Alerts 0).Annotations.summary }}{{ end }}{{ end }}'';
              message = ''{{ if gt (len .Alerts) 1 }}{{ range .Alerts }}- {{ .Annotations.summary }}
{{ end }}{{ else }}{{ if .CommonAnnotations.description }}{{ .CommonAnnotations.description }}{{ else }}{{ (index .Alerts 0).Annotations.description }}{{ end }}{{ end }}
{{ if .CommonAnnotations.runbook_url }}Runbook: {{ .CommonAnnotations.runbook_url }}{{ end }}
{{ if .CommonAnnotations.command }}Cmd: {{ .CommonAnnotations.command }}{{ end }}'';
              url = ''{{ .ExternalURL }}/#/silences/new{{ range $i, $e := .CommonLabels.SortedPairs }}{{ if eq $i 0 }}?{{ else }}&{{ end }}filter={{ $e.Name }}%3D%22{{ $e.Value | urlquery }}%22{{ end }}'';
              url_title = ''Silence this Alert Group'';
              # Note: supplementary_urls not supported by current amtool config schema; omit for compatibility
            }];
          }
          {
            name = "pushover-low";
            pushover_configs = [{
              token_file = config.sops.secrets.${cfg.receivers.pushover.tokenSecret}.path;
              user_key_file = config.sops.secrets.${cfg.receivers.pushover.userSecret}.path;
              priority = -1;
              send_resolved = true;
              title = ''{{ if gt (len .Alerts) 1 }}[{{ len .Alerts }}] {{ .CommonLabels.alertname }} on {{ or .CommonLabels.instance .CommonLabels.hostname }}{{ else }}{{ if .CommonAnnotations.summary }}{{ .CommonAnnotations.summary }}{{ else }}{{ (index .Alerts 0).Annotations.summary }}{{ end }}{{ end }}'';
              message = ''{{ if gt (len .Alerts) 1 }}{{ range .Alerts }}- {{ .Annotations.summary }}
{{ end }}{{ else }}{{ if .CommonAnnotations.description }}{{ .CommonAnnotations.description }}{{ else }}{{ (index .Alerts 0).Annotations.description }}{{ end }}{{ end }}
{{ if .CommonAnnotations.runbook_url }}Runbook: {{ .CommonAnnotations.runbook_url }}{{ end }}
{{ if .CommonAnnotations.command }}Cmd: {{ .CommonAnnotations.command }}{{ end }}'';
              url = ''{{ .ExternalURL }}/#/silences/new{{ range $i, $e := .CommonLabels.SortedPairs }}{{ if eq $i 0 }}?{{ else }}&{{ end }}filter={{ $e.Name }}%3D%22{{ $e.Value | urlquery }}%22{{ end }}'';
              url_title = ''Silence this Alert Group'';
              # Note: supplementary_urls not supported by current amtool config schema; omit for compatibility
            }];
          }
        ]
        # Append the healthchecks receiver if configured
        ++ (lib.optional (cfg.receivers.healthchecks.urlSecret != null) {
          name = "healthchecks-io";
          webhook_configs = [{
            url_file = config.sops.secrets.${cfg.receivers.healthchecks.urlSecret}.path;
            # Send resolved notifications to signal "OK" state, though most services
            # infer this from the absence of alerts.
            send_resolved = true;
          }];
        });
      };
    } // lib.optionalAttrs (cfg.alertmanager.externalUrl != null) {
      # Set external URL if configured (for alert links)
      webExternalUrl = cfg.alertmanager.externalUrl;
    };

    # Override Alertmanager service to use static user instead of DynamicUser
    # This is required for reading SOPS secrets with group=alertmanager ownership
    systemd.services.alertmanager = {
      serviceConfig = {
        DynamicUser = lib.mkForce false;
      };
    };

    # Directory is managed by ZFS storage module on hosts (zfs-service-datasets)
    # No tmpfiles rule needed here.

    # Boot and shutdown system events
    systemd.services = {
        alert-boot = {
          description = "Send boot event to Alertmanager";
          wantedBy = [ "multi-user.target" ];
          wants = [ "network-online.target" "alertmanager.service" ];
          after = [ "network-online.target" "alertmanager.service" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
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
  });
}
