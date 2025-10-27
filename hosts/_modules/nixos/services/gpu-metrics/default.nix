{ lib, pkgs, config, ... }:
let
  cfg = config.modules.services.gpuMetrics;
in
{
  options.modules.services.gpuMetrics = {
    enable = lib.mkEnableOption "host-level GPU metrics exporter (textfile for Prometheus)";

    vendor = lib.mkOption {
      type = lib.types.enum [ "auto" "intel" ];
      default = "auto";
      description = "GPU vendor to target for metrics (currently intel supported)";
    };

    interval = lib.mkOption {
      type = lib.types.str;
      default = "minutely";
      description = "Metrics collection interval (systemd OnCalendar token)";
    };

    prometheus = {
      metricsDir = lib.mkOption {
        type = lib.types.path;
        default = "/var/lib/node_exporter/textfile_collector";
        description = "Directory for Node Exporter textfile collector metrics";
      };
    };

    # Service identity (defaults align with textfile dir ownership)
    user = lib.mkOption {
      type = lib.types.str;
      default = "node-exporter";
      description = "User to run the GPU metrics exporter as";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "node-exporter";
      description = "Group to run the GPU metrics exporter as";
    };
  };

  config = lib.mkIf cfg.enable {
    # Intel GPU exporter using intel_gpu_top JSON snapshot
    systemd.services.gpu-metrics-exporter = {
      description = "Host GPU metrics exporter (Intel)";
      path = with pkgs; [ intel-gpu-tools jq coreutils gawk gnused util-linux ];
      serviceConfig = {
        Type = "oneshot";
        # Run as node-exporter with minimal privileges
        User = cfg.user;
        Group = cfg.group;
        SupplementaryGroups = [ "render" ];
        AmbientCapabilities = [ "CAP_PERFMON" ];
        UMask = "0007";

        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        NoNewPrivileges = true;
        ReadWritePaths = [ cfg.prometheus.metricsDir ];
      };
      script = ''
        set -euo pipefail
        METRICS_DIR=${cfg.prometheus.metricsDir}
        METRICS_FILE="$METRICS_DIR/gpu.prom"
        TMP="$METRICS_FILE.tmp"
        mkdir -p "$METRICS_DIR"

        TS=$(date +%s)
        ERROR=0
        JSON=""

        # For now support Intel. If vendor is auto or intel, attempt collection.
        if [ "${cfg.vendor}" = "intel" ] || [ "${cfg.vendor}" = "auto" ]; then
          if JSON=$(timeout 5 intel_gpu_top -J -s 1000 -o - 2>/dev/null | tail -n 1); then
            :
          else
            ERROR=1
          fi
        else
          ERROR=1
        fi

        {
          echo "# HELP gpu_metrics_last_run_timestamp Last GPU metrics run timestamp"
          echo "# TYPE gpu_metrics_last_run_timestamp gauge"
          echo "gpu_metrics_last_run_timestamp{hostname=\"${config.networking.hostName}\"} $TS"

          if [ "$ERROR" -eq 0 ] && echo "$JSON" | jq -e . >/dev/null 2>&1; then
            # Per-engine busy percent
            echo "$JSON" | jq -r '.engines[] | select(.class) | [.class, (.busy // 0)] | @tsv' | while IFS=$'\t' read -r klass busy; do
              label=$(echo "$klass" | sed 's/\s\+/_/g')
              printf "gpu_engine_busy_percent{hostname=\"%s\",engine=\"%s\"} %s\n" "${config.networking.hostName}" "$label" "$busy"
            done

            # Overall approx utilization: max of engine busy
            OVERALL=$(echo "$JSON" | jq -r '[.engines[].busy // 0] | max // 0')
            echo "# HELP gpu_utilization_percent Approximate overall GPU utilization percent"
            echo "# TYPE gpu_utilization_percent gauge"
            printf "gpu_utilization_percent{hostname=\"%s\"} %s\n" "${config.networking.hostName}" "$OVERALL"

            echo "# HELP gpu_metrics_error Error flag for GPU metrics collection (1=error)"
            echo "# TYPE gpu_metrics_error gauge"
            echo "gpu_metrics_error{hostname=\"${config.networking.hostName}\"} 0"
          else
            echo "# HELP gpu_metrics_error Error flag for GPU metrics collection (1=error)"
            echo "# TYPE gpu_metrics_error gauge"
            echo "gpu_metrics_error{hostname=\"${config.networking.hostName}\"} 1"
          fi
        } > "$TMP"

        mv "$TMP" "$METRICS_FILE"
      '';
    };

    systemd.timers.gpu-metrics-exporter = {
      description = "Timer for host GPU metrics exporter";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.interval;
        Persistent = true;
        RandomizedDelaySec = "30s";
      };
    };

    # Alerts can be defined at host level; here we just assert pre-reqs
    assertions = [
      {
        assertion = config.services.prometheus.exporters.node.enable or false;
        message = "GPU metrics exporter requires node exporter (textfile collector) to be enabled";
      }
    ];
  };
}
