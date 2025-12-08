# hosts/_modules/nixos/alerting/default.nix
{ lib, config, pkgs, ... }:

let
  inherit (lib) mkOption types mkIf filterAttrs mapAttrsToList;

  cfg = config.modules.alerting;

  # Helper function to generate Pushover receiver configurations
  # Reduces duplication by generating all severity-level receivers from a simple spec
  # NOTE: Go template variables use $name syntax, but NixOS's alertmanager module
  # uses envsubst to substitute environment variables. We must escape $ as $$
  # so envsubst produces literal $ in the output for Go templates.
  mkPushoverReceiver = { name, priority, emoji }: {
    name = "pushover-${name}";
    pushover_configs = [{
      token_file = config.sops.secrets.${cfg.receivers.pushover.tokenSecret}.path;
      user_key_file = config.sops.secrets.${cfg.receivers.pushover.userSecret}.path;
      priority = priority;
      send_resolved = true;
      # Title: Show ✅ RESOLVED or appropriate emoji + severity for firing alerts
      # Include count of firing alerts, or "RESOLVED" status indicator
      title = ''{{ if eq .Status "resolved" }}✅ RESOLVED: {{ or .GroupLabels.alertname .CommonLabels.alertname "Alert" }}{{ else }}${emoji} ${lib.toUpper name}: {{ or .GroupLabels.alertname .CommonLabels.alertname "Multiple Alerts" }} ({{ .Alerts.Firing | len }}){{ end }}'';
      message = ''
        {{- if eq .Status "resolved" -}}
        {{- /* Resolved alerts section */ -}}
        {{- range $$i, $$alert := .Alerts.Resolved -}}
        {{- if lt $$i 5 }}
        ✓ {{ or $$alert.Annotations.summary $$alert.Annotations.message "Alert resolved" }}
        {{- end -}}
        {{- end -}}
        {{- if gt (len .Alerts.Resolved) 5 }}
        ... and more ({{ len .Alerts.Resolved }} total resolved).
        {{- end }}

        Duration: {{ with (index .Alerts.Resolved 0) }}{{ .StartsAt.Format "15:04" }} → {{ .EndsAt.Format "15:04 MST" }}{{ end }}
        {{- else -}}
        {{- /* Firing alerts section */ -}}
        {{- range $$i, $$alert := .Alerts.Firing -}}
        {{- if lt $$i 10 }}
         • {{ or $$alert.Annotations.summary $$alert.Annotations.message "No summary" }}
        {{- if $$alert.Annotations.description }}
           {{ $$alert.Annotations.description }}
        {{- end }}
        {{- end -}}
        {{- end -}}
        {{- if gt (len .Alerts.Firing) 10 }}
        ... and more alerts ({{ len .Alerts.Firing }} total).
        {{- end }}
        {{- end }}

        {{- with .CommonLabels }}
        Host: {{ .instance }}
        {{- if .service }}
        Service: {{ .service }}
        {{- end }}
        {{- if .category }}
        Category: {{ .category }}
        {{- end }}
        {{- if .dataset }}
        Dataset: {{ .dataset }}
        {{- end }}
        {{- if .target_host }}
        Target: {{ .target_host }}
        {{- end }}
        {{- if .repository }}
        Repository: {{ .repository }}
        {{- end }}
        {{- end }}'';
      html = true;
      url = ''{{ if gt (len .Alerts) 0 }}{{ (index .Alerts 0).GeneratorURL }}{{ else }}{{ .ExternalURL }}{{ end }}'';
      url_title = ''{{ if eq .Status "resolved" }}View History{{ else }}View in Prometheus{{ end }}'';
    }];
  };

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
        default = { };
        description = "Additional labels (e.g., { service = \"sonarr\"; category = \"systemd\"; }).";
      };

      annotations = mkOption {
        type = types.attrsOf types.str;
        default = { };
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
        default = { };
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

  # Note: The am-postalert helper script was removed as boot/shutdown event alerts have been
  # replaced with Prometheus-native HostRebooted rule. Event-based alerts (systemd OnFailure)
  # were never fully implemented and the infrastructure is not currently needed.
  # If event-based alerts are needed in the future, consider using prometheus-alertmanager-webhook
  # or similar dedicated tooling rather than custom shell scripts.

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

    receivers.oncall = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = "Enable Grafana OnCall as a notification receiver.";
      };

      webhookUrlSecret = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "SOPS secret name that contains the Grafana OnCall Alertmanager integration webhook URL.";
      };
    };

    rules = mkOption {
      type = types.attrsOf ruleSubmodule;
      default = { };
      description = "Alert rules keyed by rule ID (e.g., \"sonarr-failure\").";
    };

    prometheus.ruleFilePath = mkOption {
      type = types.path;
      readOnly = true;
      description = "Path to the generated Prometheus alert rules file.";
    };

  };

  config = mkIf cfg.enable (
    let
      # Move promqlRules and prometheusRuleFile computation inside config block
      # to avoid infinite recursion when referencing cfg.rules
      promqlRules = filterAttrs (_: rule: rule.type == "promql") cfg.rules;

      prometheusRuleFile = pkgs.writeText "prometheus-alert-rules.yml" (
        lib.generators.toYAML { } {
          groups = [{
            name = "homelab-alerts";
            interval = "15s";
            rules = mapAttrsToList
              (_name: rule: {
                alert = rule.alertname;
                expr = rule.expr;
                for = rule.for;
                # Prometheus automatically creates an alertname label from the alert field
                # No need to add it manually
                labels = rule.labels // {
                  severity = rule.severity;
                };
                annotations = rule.annotations // {
                  summary = rule.annotations.summary or "Alert ${rule.alertname} fired";
                  description = rule.annotations.description or "Alert ${rule.alertname} requires attention";
                };
              })
              promqlRules;
          }];
        }
      );
    in
    {
      # Expose the generated Prometheus rule file path
      modules.alerting.prometheus.ruleFilePath = prometheusRuleFile;
      # Assertions for rule correctness to keep things type-safe
      assertions =
        let ruleNames = builtins.attrNames (cfg.rules or { });
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
        (map
          (r:
            {
              assertion = (cfg.rules.${r}.type != "promql") || (cfg.rules.${r}.expr != null);
              message = "modules.alerting.rules.${r}: PromQL rule must set 'expr'.";
            }
          )
          ruleNames)
        ++
        # Event rules typically should set alertname
        (map
          (r:
            {
              assertion = (cfg.rules.${r}.alertname != "");
              message = "modules.alerting.rules.${r}: 'alertname' must not be empty.";
            }
          )
          ruleNames)
        ++
        # Check for duplicate alertnames across all rules
        (
          let
            allAlertnames = builtins.filter (a: a != "") (map (r: cfg.rules.${r}.alertname) ruleNames);
            uniqueAlertnames = lib.unique allAlertnames;
            hasDuplicates = (builtins.length allAlertnames) != (builtins.length uniqueAlertnames);
            findDuplicates = names:
              let
                counts = lib.listToAttrs (map (name: { name = name; value = builtins.length (builtins.filter (n: n == name) names); }) (lib.unique names));
                duplicates = builtins.filter (name: counts.${name} > 1) (builtins.attrNames counts);
              in
              duplicates;
            duplicateList = if hasDuplicates then (builtins.concatStringsSep ", " (findDuplicates allAlertnames)) else "";
          in
          [{
            assertion = !hasDuplicates;
            message = "modules.alerting: Duplicate alertname labels found: ${duplicateList}. Each alert must have a unique alertname to avoid confusing grouping in Alertmanager.";
          }]
        );

      # Ensure alertmanager user/group exists before SOPS tries to install secrets
      users.users.alertmanager = {
        isSystemUser = true;
        group = "alertmanager";
      };
      users.groups.alertmanager = { };

      # Contribute Alertmanager as a Grafana datasource (contribution pattern)
      # This enables Grafana to query Alertmanager for active alerts, silences, etc.
      modules.services.grafana.integrations.alertmanager = lib.mkIf (config.modules.services.grafana.enable or false) {
        datasources.alertmanager = {
          name = "Alertmanager";
          uid = "alertmanager";
          type = "alertmanager";
          access = "proxy";
          url = cfg.alertmanager.url;
          jsonData = {
            # Use Prometheus alertmanager implementation (vs Mimir/Cortex)
            implementation = "prometheus";
            # Allow Grafana to manage silences via this datasource
            handleGrafanaManagedAlerts = false;
          };
        };
      };

      # Alertmanager configuration using native *_file pattern for secrets
      services.prometheus.alertmanager = {
        enable = true;
        configuration = {
          route = {
            # Default receiver: OnCall if enabled, otherwise Pushover medium
            receiver = if cfg.receivers.oncall.enable then "grafana-oncall" else "pushover-medium";
            # When OnCall is enabled: minimal grouping - let OnCall handle alert correlation
            # When OnCall is disabled: group by hostname/job to reduce Pushover spam
            group_by = if cfg.receivers.oncall.enable then [ "alertname" ] else [ "hostname" "job" ];
            # Fast delivery to OnCall (it handles its own batching)
            # Slower for Pushover to catch cascading failures
            group_wait = if cfg.receivers.oncall.enable then "10s" else "45s";
            # OnCall: fast resolution delivery (30s) - OnCall does its own grouping
            # Pushover: batch updates to reduce notification spam (5m)
            group_interval = if cfg.receivers.oncall.enable then "30s" else "5m";
            # Default repeat interval for medium alerts
            repeat_interval = "6h";
            routes =
              # Prepend a route for the Dead Man's Switch to ensure it's handled first
              (lib.optional (cfg.receivers.healthchecks.urlSecret != null) {
                matchers = [ "alertname=\"Watchdog\"" ];
                receiver = "healthchecks-io";
                # Do not continue to other routes
                continue = false;
                # Send frequently to maintain heartbeat
                group_interval = "1m";
                repeat_interval = "1m";
              })
              # Meta-monitoring alerts go directly to Pushover (bypass OnCall to avoid circular dependency)
              # If OnCall is down, we still want to know about monitoring issues
              ++ [{
                matchers = [ "alertname=~\"AlertmanagerDown|OnCallDown|PrometheusDown\"" ];
                receiver = "pushover-critical";
                continue = false;
                group_wait = "15s";
                repeat_interval = "15m";
              }]
              # Grouping routes only needed when NOT using OnCall (Pushover needs grouping)
              ++ (lib.optionals (!cfg.receivers.oncall.enable) [
                # System/container alerts: group all host-level issues together
                {
                  matchers = [ "category=~\"system|container\"" ];
                  group_by = [ "hostname" ];
                  continue = true;
                }
                # Backup-specific grouping: group by host and repository for clarity
                {
                  matchers = [ "category=\"restic\"" ];
                  group_by = [ "hostname" "alertname" "repository" ];
                  continue = true;
                }
                # Storage-specific grouping: consolidate ZFS alerts
                {
                  matchers = [ "category=~\"zfs|syncoid\"" ];
                  group_by = [ "instance" "alertname" "target_host" ];
                  continue = true;
                }
              ])
              # When OnCall is enabled: ALL alerts go to OnCall (no Pushover redundancy)
              # OnCall handles escalation via its own Pushover webhook
              # Meta-monitoring alerts (OnCallDown, etc.) already bypass OnCall above
              # This eliminates double-notifications while maintaining safety via meta-alerts
              #
              # Note: We don't need severity-specific routes here because:
              # - Default receiver is already grafana-oncall
              # - OnCall handles escalation policies internally
              # - Meta-alerts bypass OnCall and go directly to Pushover (configured above)
              # When OnCall is disabled OR for non-critical alerts when OnCall is enabled:
              # Route to appropriate Pushover receiver based on severity
              ++ (lib.optionals (!cfg.receivers.oncall.enable) [
                {
                  matchers = [ "severity=\"critical\"" ];
                  receiver = "pushover-critical";
                  # Slightly more patient for critical alerts to catch related failures
                  group_wait = "15s";
                  repeat_interval = "15m";
                  continue = false; # Terminal route - stop routing after this
                }
                {
                  matchers = [ "severity=\"high\"" ];
                  receiver = "pushover-high";
                  # Allow time for related alerts to group together
                  group_wait = "30s";
                  repeat_interval = "1h";
                  continue = false; # Terminal route - stop routing after this
                }
                {
                  matchers = [ "severity=\"medium\"" ];
                  receiver = "pushover-medium";
                  repeat_interval = "6h";
                  continue = false; # Terminal route - stop routing after this
                }
                {
                  matchers = [ "severity=\"low\"" ];
                  receiver = "pushover-low";
                  repeat_interval = "12h"; # Low severity should repeat less frequently than medium
                  continue = false; # Terminal route - stop routing after this
                }
              ]);
          };

          # Inhibition rules to prevent redundant alerts
          # When a critical alert is active, suppress less severe related alerts
          inhibit_rules = [
            # CRITICAL: Suppress all alerts from a host when it is unreachable
            # This is the most important rule for preventing alert storms
            # When a host goes down, we don't need alerts for every service on that host
            {
              source_matchers = [
                "alertname=\"InstanceDown\""
              ];
              target_matchers = [
                "alertname!=\"InstanceDown\""
              ];
              # Only suppress alerts from the same instance
              equal = [ "instance" ];
            }
            # Suppress high-severity ZFS replication alerts when critical alert is firing
            # Prevents alert fatigue when both StaleHigh and StaleCritical fire for same replication
            {
              source_matchers = [
                "severity=\"critical\""
                "alertname=~\"ZFSReplication.*\""
              ];
              target_matchers = [
                "severity=\"high\""
                "alertname=~\"ZFSReplication.*\""
              ];
              # Only inhibit if same dataset and target
              equal = [ "dataset" "target_host" ];
            }
            # Suppress replication noise when the target host is down
            # Requires an InstanceDown alert for the target host
            # CRITICAL DEPENDENCY: This rule requires that:
            #   1. ReplicationTargetUnreachable alert has a 'target_host' label
            #   2. ZFS replication alerts have a matching 'target_host' label
            #   3. Both labels use identical formatting (e.g., 'nas-1.holthome.net')
            # If labels don't match exactly, inhibition will silently fail
            {
              target_matchers = [
                "alertname=~\"SyncoidUnitFailed|ZFSReplicationStale.*|ZFSReplicationLagHigh|ZFSReplicationStalled\""
              ];
              source_matchers = [
                "alertname=\"ReplicationTargetUnreachable\""
              ];
              # Match target_host in the replication alert with target_host in the unreachable alert
              equal = [ "target_host" ];
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
          # Generate Pushover receivers for all severity levels using helper function
          # This reduces code duplication and makes template updates consistent
          receivers = [
            (mkPushoverReceiver { name = "critical"; priority = 1; emoji = "🚨"; })
            (mkPushoverReceiver { name = "high"; priority = 1; emoji = "⚠️"; })
            (mkPushoverReceiver { name = "medium"; priority = 0; emoji = "⚠️"; })
            (mkPushoverReceiver { name = "low"; priority = -1; emoji = "ℹ️"; })
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
          })
          # Append the Grafana OnCall receiver if configured
          # OnCall provides escalation policies, on-call schedules, and incident management
          ++ (lib.optional (cfg.receivers.oncall.enable && cfg.receivers.oncall.webhookUrlSecret != null) {
            name = "grafana-oncall";
            webhook_configs = [{
              url_file = config.sops.secrets.${cfg.receivers.oncall.webhookUrlSecret}.path;
              send_resolved = true;
              # OnCall expects Alertmanager webhook format natively
              http_config = {
                follow_redirects = true;
              };
            }];
          });
        };
      } // {
        # Set external URL for alert links, falling back to internal URL if not specified
        # This ensures .ExternalURL in templates is always valid
        webExternalUrl = cfg.alertmanager.externalUrl or cfg.alertmanager.url;
      };

      # Override Alertmanager service to use static user instead of DynamicUser
      # This is required for reading SOPS secrets with group=alertmanager ownership
      systemd.services.alertmanager = {
        serviceConfig = {
          DynamicUser = lib.mkForce false;
          User = "alertmanager";
          Group = "alertmanager";
        };
      };

      # Directory is managed by ZFS storage module on hosts (zfs-service-datasets)
      # No tmpfiles rule needed here.

      # Note: Boot/shutdown event alerts were removed in favor of Prometheus-native approach
      # Rationale: Systemd-based alerts are fragile (shutdown alerts fail when network is down,
      # boot alerts have race conditions) and create noise in homelab environments where reboots
      # are typically planned maintenance. The PromQL-based HostRebooted rule (using
      # node_boot_time_seconds metric) provides superior reliability, context, and signal-to-noise.
      # See: modules.alerting.rules."host-rebooted" for the replacement implementation.
    }
  );
}
