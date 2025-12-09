{ lib, pkgs, config, ... }:
let
  cfg = config.modules.services.gpuMetrics;

  # Script for GPU metrics collection
  # Using a simple script that we can debug step by step
  gpuMetricsScript = pkgs.writeShellScript "gpu-metrics-collector" ''
        set -euo pipefail

        # Add required tools to PATH
        export PATH="${lib.makeBinPath (with pkgs; [ coreutils gnugrep jq gawk ])}:$PATH"

        METRICS_DIR=${cfg.prometheus.metricsDir}
        METRICS_FILE="$METRICS_DIR/gpu.prom"
        TMP_FILE="$METRICS_FILE.tmp"
        mkdir -p "$METRICS_DIR"

        # Test if wrapper exists and has capabilities
        if [ ! -x /run/wrappers/bin/intel_gpu_top ]; then
          echo "gpu-metrics-exporter: intel_gpu_top wrapper not found" >&2
          cat > "$TMP_FILE" <<EOF
    # HELP gpu_metrics_error Error flag for GPU metrics collection (1=error)
    # TYPE gpu_metrics_error gauge
    gpu_metrics_error{hostname="${config.networking.hostName}"} 1
    EOF
          mv "$TMP_FILE" "$METRICS_FILE"
          exit 1
        fi

        # Dynamically detect Intel GPU device by vendor ID (0x8086)
        TMPOUT=$(mktemp)
        trap 'rm -f "$TMPOUT"' EXIT

        INTEL_CARD=""
        for card in /sys/class/drm/card*; do
          if [ -f "$card/device/vendor" ] && [ "$(cat "$card/device/vendor")" = "0x8086" ]; then
            INTEL_CARD=$(basename "$card")
            break
          fi
        done

        if [ -z "$INTEL_CARD" ]; then
          echo "gpu-metrics-exporter: Could not find an Intel GPU device" >&2
          cat > "$TMP_FILE" <<EOF
    # HELP gpu_metrics_error Error flag for GPU metrics collection (1=error)
    # TYPE gpu_metrics_error gauge
    gpu_metrics_error{hostname="${config.networking.hostName}"} 1
    EOF
          mv "$TMP_FILE" "$METRICS_FILE"
          exit 1
        fi

        # Use timeout command instead of background + sleep + kill for safer process management
        # timeout exits with 124 if command times out (expected behavior)
        if ! timeout 3s /run/wrappers/bin/intel_gpu_top -d "drm:/dev/dri/$INTEL_CARD" -J -s 1000 -o - > "$TMPOUT" 2>&1; then
          # Only fail if no output was produced (empty file)
          if [ ! -s "$TMPOUT" ]; then
            echo "gpu-metrics-exporter: intel_gpu_top failed or produced no output" >&2
            cat "$TMPOUT" >&2
            cat > "$TMP_FILE" <<EOF
    # HELP gpu_metrics_error Error flag for GPU metrics collection (1=error)
    # TYPE gpu_metrics_error gauge
    gpu_metrics_error{hostname="${config.networking.hostName}"} 1
    EOF
            mv "$TMP_FILE" "$METRICS_FILE"
            exit 1
          fi
        fi

        # Extract the last complete JSON object
        # When killed, intel_gpu_top outputs incomplete JSON: [ { ... } { ... }
        # (missing closing ] and commas between objects)
        # Strategy: Skip first line (the '['), then use jq to slurp and get last object
        # tail -n +2 skips the opening bracket, jq -s slurps the stream into an array
        if ! JSON_OUTPUT=$(tail -n +2 "$TMPOUT" | jq -es '.[-1]'); then
          echo "gpu-metrics-exporter: intel_gpu_top failed or produced no JSON output" >&2
          cat "$TMPOUT" >&2

          # Write error metric and exit non-zero
          cat > "$TMP_FILE" <<EOF
    # HELP gpu_metrics_error Error flag for GPU metrics collection (1=error)
    # TYPE gpu_metrics_error gauge
    gpu_metrics_error{hostname="${config.networking.hostName}"} 1
    EOF
          mv "$TMP_FILE" "$METRICS_FILE"
          exit 1
        fi

        # Validate JSON structure contains required .engines key
        if ! echo "$JSON_OUTPUT" | jq -e '.engines' > /dev/null; then
          echo "gpu-metrics-exporter: JSON output is valid but missing required '.engines' key" >&2
          echo "$JSON_OUTPUT" >&2

          # Write error metric and exit non-zero
          cat > "$TMP_FILE" <<EOF
    # HELP gpu_metrics_error Error flag for GPU metrics collection (1=error)
    # TYPE gpu_metrics_error gauge
    gpu_metrics_error{hostname="${config.networking.hostName}"} 1
    EOF
          mv "$TMP_FILE" "$METRICS_FILE"
          exit 1
        fi

        # On success, write the full metrics file
        {
          # The last_run_timestamp is now only updated on success
          # This makes the "GpuExporterStale" alert meaningful
          echo "# HELP gpu_metrics_last_run_timestamp Last successful GPU metrics run timestamp"
          echo "# TYPE gpu_metrics_last_run_timestamp gauge"
          echo "gpu_metrics_last_run_timestamp{hostname=\"${config.networking.hostName}\"} $(date +%s)"

          # Per-engine busy percent
          # Extract engines as key-value pairs since the JSON structure uses engine names as keys
          echo "# HELP gpu_engine_busy_percent Per-engine GPU busy utilization percent"
          echo "# TYPE gpu_engine_busy_percent gauge"
          echo "$JSON_OUTPUT" | jq -r '.engines | to_entries[] | [.key, (.value.busy // 0)] | @tsv' | while IFS=$'\t' read -r klass busy; do
            label="''${klass// /_}"
            printf "gpu_engine_busy_percent{hostname=\"%s\",engine=\"%s\"} %s\n" "${config.networking.hostName}" "$label" "$busy"
          done

          # Overall approx utilization: max of engine busy
          OVERALL=$(echo "$JSON_OUTPUT" | jq -r '[.engines[].busy // 0] | max // 0')
          echo "# HELP gpu_utilization_percent Approximate overall GPU utilization percent"
          echo "# TYPE gpu_utilization_percent gauge"
          printf "gpu_utilization_percent{hostname=\"%s\"} %s\n" "${config.networking.hostName}" "$OVERALL"

          echo "# HELP gpu_metrics_error Error flag for GPU metrics collection (1=error)"
          echo "# TYPE gpu_metrics_error gauge"
          echo "gpu_metrics_error{hostname=\"${config.networking.hostName}\"} 0"
        } > "$TMP_FILE"

        mv "$TMP_FILE" "$METRICS_FILE"
  '';
in
{
  options.modules.services.gpuMetrics = {
    enable = lib.mkEnableOption "host-level GPU metrics exporter (textfile for Prometheus)";

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
    # Grant CAP_PERFMON to intel_gpu_top binary directly
    security.wrappers.intel_gpu_top = {
      owner = "root";
      group = "render";
      capabilities = "cap_perfmon+ep";
      source = "${pkgs.intel-gpu-tools}/bin/intel_gpu_top";
    };

    # Intel GPU exporter using intel_gpu_top JSON snapshot
    systemd.services.gpu-metrics-exporter = {
      description = "Host GPU metrics exporter (Intel)";
      serviceConfig = {
        Type = "oneshot";
        # Run as node-exporter with minimal privileges
        User = cfg.user;
        Group = cfg.group;
        SupplementaryGroups = [ "render" ];

        # Using security.wrappers for CAP_PERFMON instead of AmbientCapabilities
        # This is more reliable as the capability is set on the binary itself

        UMask = "0002";

        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [ cfg.prometheus.metricsDir ];

        # Use ExecStart for direct execution
        ExecStart = "${gpuMetricsScript}";
      };
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
