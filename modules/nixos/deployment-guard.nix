{ config, lib, pkgs, ... }:

let
  cfg = config.modules.deploymentGuard;
  runtimeDir = "/run/nixos-deploy-backup-guard";
  markerFile = "/run/nixos-apply-paused-backup-timers";
  lockFile = "/run/lock/nixos-deploy-backup-guard.lock";
  expectedTimersFile = "/etc/nixos-deploy-backup-guard/expected-backup-timers";
  metricsFile = "${cfg.metrics.textfileDirectory}/nixos_deploy_backup_guard.prom";

  expectedBackupTimers =
    map (name: "${name}.timer")
      (builtins.attrNames
        (lib.filterAttrs
          (name: timer:
            builtins.match "(restic-backups?-.*|pgbackrest-.*|syncoid-.*|sanoid)" name != null
            && (timer.wantedBy or [ ]) != [ ])
          config.systemd.timers));

  expectedTimersSource = pkgs.writeText "expected-backup-timers" (
    lib.concatMapStringsSep "\n" (timer: timer) expectedBackupTimers + "\n"
  );

  guardCommand = pkgs.writeShellApplication {
    name = "nixos-deploy-backup-guard";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gawk
      pkgs.gnugrep
      pkgs.gnused
      pkgs.procps
      pkgs.systemd
      pkgs.util-linux
    ];
    text = ''
      runtime_dir=''${NIXOS_DEPLOY_GUARD_RUNTIME_DIR:-${runtimeDir}}
      marker_file=''${NIXOS_DEPLOY_GUARD_MARKER_FILE:-${markerFile}}
      lock_file=''${NIXOS_DEPLOY_GUARD_LOCK_FILE:-${lockFile}}
      systemd_runtime_dir=''${NIXOS_DEPLOY_GUARD_SYSTEMD_RUNTIME_DIR:-/run/systemd/system}
      systemctl_command=''${NIXOS_DEPLOY_GUARD_SYSTEMCTL:-systemctl}
      systemd_run_command=''${NIXOS_DEPLOY_GUARD_SYSTEMD_RUN:-systemd-run}
      true_command=''${NIXOS_DEPLOY_GUARD_TRUE:-/run/current-system/sw/bin/true}
      max_hold_seconds=''${NIXOS_DEPLOY_GUARD_MAX_HOLD_SECONDS:-${toString cfg.maxHoldSeconds}}
      owner_id_file="$runtime_dir/owner-id"
      owner_pid_file="$runtime_dir/owner-pid"
      owner_process_start_file="$runtime_dir/owner-process-start"
      owner_started_file="$runtime_dir/owner-started"
      restore_success_file="$runtime_dir/last-restore-success"
      restore_timestamp_file="$runtime_dir/last-restore-timestamp"
      restore_recorded_file="$runtime_dir/last-restore-recorded"
      restore_active_file="$runtime_dir/last-restore-active"
      restore_removed_file="$runtime_dir/last-restore-removed"
      guard_held=false

      require_root() {
        if (( EUID != 0 )) && [[ "''${NIXOS_DEPLOY_GUARD_TEST_MODE:-0}" != 1 ]]; then
          echo "nixos-deploy-backup-guard must run as root" >&2
          exit 1
        fi
      }

      write_value() {
        local path=$1
        local value=$2
        printf '%s\n' "$value" > "$path.tmp"
        mv "$path.tmp" "$path"
      }

      process_start_ticks() {
        local pid=$1
        awk '{ print $22 }' "/proc/$pid/stat" 2>/dev/null
      }

      owner_process_is_alive() {
        local owner_pid=$1
        local expected_start=$2
        local actual_start

        if [[ ! "$owner_pid" =~ ^[0-9]+$ || ! "$expected_start" =~ ^[0-9]+$ ]]; then
          return 1
        fi
        actual_start=$(process_start_ticks "$owner_pid")
        [[ -n "$actual_start" && "$actual_start" == "$expected_start" ]]
      }

      record_restore_result() {
        local success=$1
        local recorded=$2
        local active=$3
        local removed=$4
        write_value "$restore_success_file" "$success"
        write_value "$restore_timestamp_file" "$(date +%s)"
        write_value "$restore_recorded_file" "$recorded"
        write_value "$restore_active_file" "$active"
        write_value "$restore_removed_file" "$removed"
      }

      read_timer_file() {
        local path=$1
        local -n destination=$2
        destination=()
        [[ -f "$path" ]] || return 0
        while IFS= read -r timer; do
          [[ -n "$timer" ]] || continue
          if [[ ! "$timer" =~ ^[A-Za-z0-9_.@:-]+\.timer$ ]]; then
            echo "Refusing invalid timer name in $path: $timer" >&2
            return 1
          fi
          destination+=("$timer")
        done < "$path"
      }

      restore_timers() {
        local -a recorded_timers valid_timers removed_timers inactive_timers remaining_dropins
        local timer dropin_dir
        local restore_failed=0

        if [[ ! -f "$marker_file" ]]; then
          record_restore_result 1 0 0 0
          return 0
        fi

        if ! read_timer_file "$marker_file" recorded_timers; then
          record_restore_result 0 0 0 0
          return 1
        fi
        valid_timers=()
        removed_timers=()
        inactive_timers=()
        remaining_dropins=()

        for timer in "''${recorded_timers[@]}"; do
          dropin_dir="$systemd_runtime_dir/$timer.d"
          rm -f "$dropin_dir/90-nixos-apply-guard.conf"
          rmdir "$dropin_dir" 2>/dev/null || true
        done

        if ! "$systemctl_command" daemon-reload; then
          echo "Failed to reload systemd while restoring backup timers" >&2
          restore_failed=1
        fi

        for timer in "''${recorded_timers[@]}"; do
          if "$systemctl_command" cat "$timer" >/dev/null 2>&1; then
            valid_timers+=("$timer")
          else
            removed_timers+=("$timer")
          fi
        done

        if (( ''${#valid_timers[@]} > 0 )); then
          if ! "$systemctl_command" start "''${valid_timers[@]}"; then
            echo "One or more backup timers failed to start" >&2
            restore_failed=1
          fi
        fi

        for timer in "''${valid_timers[@]}"; do
          if ! "$systemctl_command" is-active --quiet "$timer"; then
            inactive_timers+=("$timer")
          fi
          if [[ -e "$systemd_runtime_dir/$timer.d/90-nixos-apply-guard.conf" ]]; then
            remaining_dropins+=("$timer")
          fi
        done

        if (( ''${#inactive_timers[@]} > 0 )); then
          printf 'Backup timers still inactive after restoration:\n%s\n' "''${inactive_timers[*]}" >&2
          restore_failed=1
        fi
        if (( ''${#remaining_dropins[@]} > 0 )); then
          printf 'Backup timer guard drop-ins still present:\n%s\n' "''${remaining_dropins[*]}" >&2
          restore_failed=1
        fi

        if (( restore_failed != 0 )); then
          record_restore_result 0 "''${#recorded_timers[@]}" \
            "$(( ''${#valid_timers[@]} - ''${#inactive_timers[@]} ))" "''${#removed_timers[@]}"
          return 1
        fi

        rm -f "$marker_file"
        record_restore_result 1 "''${#recorded_timers[@]}" \
          "''${#valid_timers[@]}" "''${#removed_timers[@]}"
        printf 'RESTORED recorded=%d active=%d removed=%d dropins=0\n' \
          "''${#recorded_timers[@]}" "''${#valid_timers[@]}" "''${#removed_timers[@]}"
      }

      pause_timers() {
        local -a timers active_jobs
        local timer dropin_dir backup_unit_pattern remaining_jobs failed_jobs after_units

        timers=()
        while IFS= read -r timer; do
          [[ -n "$timer" ]] || continue
          timers+=("$timer")
        done < <(
          "$systemctl_command" list-units --type=timer --state=active --no-pager --no-legend --plain \
            | awk '{ print $1 }' \
            | grep -E '^(restic-backups?-|pgbackrest-|syncoid-|sanoid\.timer)' \
            | sort -u \
            || true
        )

        printf '%s\n' "''${timers[@]}" | sed '/^$/d' > "$marker_file.tmp"
        mv "$marker_file.tmp" "$marker_file"

        for timer in "''${timers[@]}"; do
          dropin_dir="$systemd_runtime_dir/$timer.d"
          install -d -m 0755 "$dropin_dir"
          printf '[Unit]\nConditionPathExists=!%s\n' "$marker_file" \
            > "$dropin_dir/90-nixos-apply-guard.conf"
        done
        "$systemctl_command" daemon-reload

        if (( ''${#timers[@]} > 0 )); then
          "$systemctl_command" stop "''${timers[@]}"
        fi

        backup_unit_pattern='^(restic-backups?-|pgbackrest-.*backup|syncoid-|sanoid\.service)'
        failed_jobs=$(
          "$systemctl_command" list-units --type=service --state=failed --no-pager --no-legend --plain \
            | awk '{ print $1 }' \
            | grep -E "$backup_unit_pattern" \
            | sort -u \
            || true
        )
        if [[ -n "$failed_jobs" ]]; then
          printf 'Refusing deployment; backup jobs are failed after timer quiescence:\n%s\n' "$failed_jobs" >&2
          return 1
        fi

        mapfile -t active_jobs < <(
          {
            "$systemctl_command" list-units --type=service --all --no-pager --no-legend --plain \
              | awk '$3 == "activating" || $3 == "deactivating" || $4 == "running" { print $1 }'
            "$systemctl_command" list-jobs --no-pager --no-legend \
              | awk '$3 == "start" { print $2 }'
          } \
            | grep -E "$backup_unit_pattern" \
            | sort -u \
            || true
        )

        if (( ''${#active_jobs[@]} > 0 )); then
          printf 'Waiting for in-flight backup jobs after timer quiescence:\n%s\n' "''${active_jobs[*]}"
          after_units=$(printf '%s ' "''${active_jobs[@]}")
          "$systemd_run_command" \
            --quiet \
            --wait \
            --collect \
            --unit="nixos-apply-backup-drain-$$" \
            --property="After=$after_units" \
            "$true_command"
        fi

        remaining_jobs=$(
          "$systemctl_command" list-units --type=service --all --no-pager --no-legend --plain \
            | awk '$3 == "activating" || $3 == "deactivating" || $3 == "failed" || $4 == "running" { print $1 }' \
            | grep -E "$backup_unit_pattern" \
            | sort -u \
            || true
        )
        if [[ -n "$remaining_jobs" ]]; then
          printf 'Refusing deployment; backup jobs did not drain cleanly:\n%s\n' "$remaining_jobs" >&2
          return 1
        fi

        printf 'READY %s timers=%d\n' "$(cat "$owner_id_file")" "''${#timers[@]}"
      }

      cleanup() {
        local original_status=$?
        local cleanup_status=0
        trap - EXIT INT TERM HUP
        set +e

        if [[ "$guard_held" == true ]] && ! restore_timers; then
          cleanup_status=1
        fi
        rm -f "$owner_id_file" "$owner_pid_file" "$owner_process_start_file" "$owner_started_file"

        if (( cleanup_status != 0 )); then
          exit 1
        fi
        exit "$original_status"
      }

      acquire_lock() {
        exec 9> "$lock_file"
        if ! flock -n 9; then
          echo "Another deployment backup guard already owns $lock_file" >&2
          return 1
        fi
      }

      hold_guard() {
        local deployment_id=$1
        local command

        if [[ ! "$deployment_id" =~ ^[A-Za-z0-9._:-]+$ ]]; then
          echo "Invalid deployment ID: $deployment_id" >&2
          return 2
        fi

        if ! acquire_lock; then
          return 1
        fi
        if [[ -f "$marker_file" ]]; then
          echo "Recovering backup timers left by an abandoned deployment" >&2
          restore_timers
        fi

        write_value "$owner_id_file" "$deployment_id"
        write_value "$owner_pid_file" "$$"
        write_value "$owner_process_start_file" "$(process_start_ticks "$$")"
        write_value "$owner_started_file" "$(date +%s)"
        guard_held=true
        trap cleanup EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM
        trap 'exit 129' HUP

        pause_timers

        if ! IFS= read -r -t "$max_hold_seconds" command; then
          echo "Deployment lease ended before release; restoring backup timers" >&2
          return 1
        fi
        if [[ "$command" != "release $deployment_id" ]]; then
          echo "Invalid deployment lease command: $command" >&2
          return 1
        fi
      }

      recover_guard() {
        if ! acquire_lock; then
          return 1
        fi
        if [[ ! -f "$marker_file" ]]; then
          rm -f "$owner_id_file" "$owner_pid_file" "$owner_process_start_file" "$owner_started_file"
          echo "No abandoned deployment guard state found"
          return 0
        fi
        restore_timers
        rm -f "$owner_id_file" "$owner_pid_file" "$owner_process_start_file" "$owner_started_file"
      }

      show_status() {
        local owner_id=none owner_pid=none owner_process_start=0 owner_started=0 marker_present=0 owner_alive=0
        [[ -f "$owner_id_file" ]] && owner_id=$(cat "$owner_id_file")
        [[ -f "$owner_pid_file" ]] && owner_pid=$(cat "$owner_pid_file")
        [[ -f "$owner_process_start_file" ]] && owner_process_start=$(cat "$owner_process_start_file")
        [[ -f "$owner_started_file" ]] && owner_started=$(cat "$owner_started_file")
        [[ -f "$marker_file" ]] && marker_present=1
        if owner_process_is_alive "$owner_pid" "$owner_process_start"; then
          owner_alive=1
        fi
        printf 'owner_id=%s owner_pid=%s owner_alive=%d marker_present=%d started=%s\n' \
          "$owner_id" "$owner_pid" "$owner_alive" "$marker_present" "$owner_started"
      }

      require_root
      install -d -m 0755 "$runtime_dir"

      case "''${1:-}" in
        hold)
          if (( $# != 2 )); then
            echo "usage: nixos-deploy-backup-guard hold <deployment-id>" >&2
            exit 2
          fi
          hold_guard "$2"
          ;;
        recover)
          recover_guard
          ;;
        status)
          show_status
          ;;
        *)
          echo "usage: nixos-deploy-backup-guard {hold <deployment-id>|recover|status}" >&2
          exit 2
          ;;
      esac
    '';
  };

  metricsCommand = pkgs.writeShellApplication {
    name = "nixos-deploy-backup-guard-metrics";
    runtimeInputs = [ pkgs.coreutils pkgs.gawk pkgs.systemd ];
    text = ''
      runtime_dir=''${NIXOS_DEPLOY_GUARD_RUNTIME_DIR:-${runtimeDir}}
      marker_file=''${NIXOS_DEPLOY_GUARD_MARKER_FILE:-${markerFile}}
      expected_timers_file=''${NIXOS_DEPLOY_GUARD_EXPECTED_TIMERS_FILE:-${expectedTimersFile}}
      metrics_file=''${NIXOS_DEPLOY_GUARD_METRICS_FILE:-${metricsFile}}
      systemctl_command=''${NIXOS_DEPLOY_GUARD_SYSTEMCTL:-systemctl}
      owner_pid_file="$runtime_dir/owner-pid"
      owner_process_start_file="$runtime_dir/owner-process-start"
      owner_started_file="$runtime_dir/owner-started"

      read_number() {
        local path=$1
        local fallback=$2
        local value
        if [[ -f "$path" ]]; then
          value=$(cat "$path")
          if [[ "$value" =~ ^[0-9]+$ ]]; then
            printf '%s' "$value"
            return 0
          fi
        fi
        printf '%s' "$fallback"
      }

      marker_present=0
      owner_alive=0
      guard_active=0
      [[ -f "$marker_file" ]] && marker_present=1
      owner_pid=$(read_number "$owner_pid_file" 0)
      owner_process_start=$(read_number "$owner_process_start_file" 0)
      owner_started=$(read_number "$owner_started_file" 0)
      if (( owner_pid > 0 && owner_process_start > 0 )) && [[ -r "/proc/$owner_pid/stat" ]]; then
        actual_process_start=$(awk '{ print $22 }' "/proc/$owner_pid/stat" 2>/dev/null || true)
        if [[ "$actual_process_start" == "$owner_process_start" ]]; then
          owner_alive=1
        fi
      fi
      if (( marker_present == 1 && owner_alive == 1 )); then
        guard_active=1
      fi

      expected_count=0
      active_count=0
      timer_metrics=""
      while IFS= read -r timer; do
        [[ -n "$timer" ]] || continue
        expected_count=$((expected_count + 1))
        timer_active=0
        if "$systemctl_command" is-active --quiet "$timer"; then
          timer_active=1
          active_count=$((active_count + 1))
        fi
        timer_metrics+="nixos_deploy_backup_timer_expected{timer=\"$timer\"} 1"$'\n'
        timer_metrics+="nixos_deploy_backup_timer_active{timer=\"$timer\"} $timer_active"$'\n'
      done < "$expected_timers_file"
      inactive_count=$((expected_count - active_count))

      restore_success=$(read_number "$runtime_dir/last-restore-success" 1)
      restore_timestamp=$(read_number "$runtime_dir/last-restore-timestamp" 0)
      restore_recorded=$(read_number "$runtime_dir/last-restore-recorded" 0)
      restore_active=$(read_number "$runtime_dir/last-restore-active" 0)
      restore_removed=$(read_number "$runtime_dir/last-restore-removed" 0)

      cat > "$metrics_file.tmp" <<EOF
      # HELP nixos_deploy_backup_guard_active Whether a live deployment owns the backup guard.
      # TYPE nixos_deploy_backup_guard_active gauge
      nixos_deploy_backup_guard_active $guard_active
      # HELP nixos_deploy_backup_guard_marker_present Whether the backup pause marker exists.
      # TYPE nixos_deploy_backup_guard_marker_present gauge
      nixos_deploy_backup_guard_marker_present $marker_present
      # HELP nixos_deploy_backup_guard_owner_alive Whether the recorded guard process is alive.
      # TYPE nixos_deploy_backup_guard_owner_alive gauge
      nixos_deploy_backup_guard_owner_alive $owner_alive
      # HELP nixos_deploy_backup_guard_started_timestamp_seconds Start time of the active guard.
      # TYPE nixos_deploy_backup_guard_started_timestamp_seconds gauge
      nixos_deploy_backup_guard_started_timestamp_seconds $owner_started
      # HELP nixos_deploy_backup_timers_expected Number of declaratively expected backup timers.
      # TYPE nixos_deploy_backup_timers_expected gauge
      nixos_deploy_backup_timers_expected $expected_count
      # HELP nixos_deploy_backup_timers_active Number of expected backup timers currently active.
      # TYPE nixos_deploy_backup_timers_active gauge
      nixos_deploy_backup_timers_active $active_count
      # HELP nixos_deploy_backup_timers_inactive Number of expected backup timers currently inactive.
      # TYPE nixos_deploy_backup_timers_inactive gauge
      nixos_deploy_backup_timers_inactive $inactive_count
      # HELP nixos_deploy_backup_guard_last_restore_success Whether the last timer restoration succeeded.
      # TYPE nixos_deploy_backup_guard_last_restore_success gauge
      nixos_deploy_backup_guard_last_restore_success $restore_success
      # HELP nixos_deploy_backup_guard_last_restore_timestamp_seconds Completion time of the last restoration.
      # TYPE nixos_deploy_backup_guard_last_restore_timestamp_seconds gauge
      nixos_deploy_backup_guard_last_restore_timestamp_seconds $restore_timestamp
      # HELP nixos_deploy_backup_guard_last_restore_recorded_timers Number of timers recorded before the last restoration.
      # TYPE nixos_deploy_backup_guard_last_restore_recorded_timers gauge
      nixos_deploy_backup_guard_last_restore_recorded_timers $restore_recorded
      # HELP nixos_deploy_backup_guard_last_restore_active_timers Number of surviving timers active after the last restoration.
      # TYPE nixos_deploy_backup_guard_last_restore_active_timers gauge
      nixos_deploy_backup_guard_last_restore_active_timers $restore_active
      # HELP nixos_deploy_backup_guard_last_restore_removed_timers Number of recorded timers removed by the deployed generation.
      # TYPE nixos_deploy_backup_guard_last_restore_removed_timers gauge
      nixos_deploy_backup_guard_last_restore_removed_timers $restore_removed
      # HELP nixos_deploy_backup_guard_last_check_timestamp_seconds Last deployment guard metrics check.
      # TYPE nixos_deploy_backup_guard_last_check_timestamp_seconds gauge
      nixos_deploy_backup_guard_last_check_timestamp_seconds $(date +%s)
      # HELP nixos_deploy_backup_timer_expected Whether a backup timer is declaratively expected.
      # TYPE nixos_deploy_backup_timer_expected gauge
      # HELP nixos_deploy_backup_timer_active Whether an expected backup timer is active.
      # TYPE nixos_deploy_backup_timer_active gauge
      $timer_metrics
      EOF
      mv "$metrics_file.tmp" "$metrics_file"
    '';
  };
in
{
  options.modules.deploymentGuard = {
    enable = lib.mkEnableOption "target-owned backup guard for NixOS deployments";

    _internal = {
      guardCommand = lib.mkOption {
        type = lib.types.package;
        internal = true;
        readOnly = true;
        description = "Generated target-side deployment guard command.";
      };

      metricsCommand = lib.mkOption {
        type = lib.types.package;
        internal = true;
        readOnly = true;
        description = "Generated deployment guard metrics command.";
      };

      expectedBackupTimers = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        internal = true;
        readOnly = true;
        description = "Declaratively expected active backup timer units.";
      };
    };

    maxHoldSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 14400;
      description = "Maximum deployment lease duration before backup timers are restored automatically.";
    };

    staleAfterSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 7200;
      description = "Guard age after which Prometheus reports a stale deployment lease.";
    };

    metrics = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Export deployment guard state through the node-exporter textfile collector.";
      };

      textfileDirectory = lib.mkOption {
        type = lib.types.path;
        default = "/var/lib/node_exporter/textfile_collector";
        description = "Node-exporter textfile collector directory.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    modules.deploymentGuard._internal = {
      inherit guardCommand metricsCommand expectedBackupTimers;
    };

    assertions = [
      {
        assertion = !cfg.metrics.enable || config.modules.monitoring.nodeExporter.textfileCollector.enable;
        message = "modules.deploymentGuard.metrics requires the node-exporter textfile collector.";
      }
    ];

    environment.etc."nixos-deploy-backup-guard/expected-backup-timers".source = expectedTimersSource;
    environment.systemPackages = [ guardCommand ];

    systemd.tmpfiles.rules = [
      "d ${runtimeDir} 0755 root root -"
    ];

    systemd.services.nixos-deploy-backup-guard-metrics = lib.mkIf cfg.metrics.enable {
      description = "Export NixOS deployment backup guard metrics";
      after = [ "systemd-tmpfiles-setup.service" ];
      serviceConfig = {
        Type = "oneshot";
        User = "node-exporter";
        Group = "node-exporter";
        ExecStart = lib.getExe metricsCommand;
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        ReadWritePaths = [ cfg.metrics.textfileDirectory ];
      };
    };

    systemd.timers.nixos-deploy-backup-guard-metrics = lib.mkIf cfg.metrics.enable {
      description = "Check NixOS deployment backup guard every minute";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "1m";
        OnUnitActiveSec = "1m";
        Persistent = true;
      };
    };

    modules.alerting.rules = lib.mkIf (cfg.metrics.enable && (config.modules.alerting.enable or false)) {
      "deployment-backup-guard-abandoned" = {
        type = "promql";
        alertname = "DeploymentBackupGuardAbandoned";
        expr = "nixos_deploy_backup_guard_marker_present == 1 and nixos_deploy_backup_guard_owner_alive == 0";
        for = "2m";
        severity = "critical";
        labels = { service = "nixos-deploy"; category = "backup"; };
        annotations = {
          summary = "NixOS deployment left backup timers paused on {{ $labels.instance }}";
          description = "The backup pause marker exists without a live deployment owner. Run nixos-deploy-backup-guard status, then recover after confirming no deployment is active.";
          command = "sudo nixos-deploy-backup-guard status";
        };
      };

      "deployment-backup-guard-stale" = {
        type = "promql";
        alertname = "DeploymentBackupGuardStale";
        expr = "(time() - nixos_deploy_backup_guard_started_timestamp_seconds > ${toString cfg.staleAfterSeconds}) and nixos_deploy_backup_guard_active == 1";
        for = "5m";
        severity = "high";
        labels = { service = "nixos-deploy"; category = "backup"; };
        annotations = {
          summary = "NixOS deployment backup guard has been active too long on {{ $labels.instance }}";
          description = "The deployment lease has exceeded ${toString cfg.staleAfterSeconds} seconds. Confirm whether the deployment is still running.";
          command = "sudo nixos-deploy-backup-guard status";
        };
      };

      "deployment-backup-timers-inactive" = {
        type = "promql";
        alertname = "DeploymentBackupTimersInactive";
        expr = "nixos_deploy_backup_timers_inactive > 0 and on(instance) nixos_deploy_backup_guard_active == 0";
        for = "2m";
        severity = "critical";
        labels = { service = "nixos-deploy"; category = "backup"; };
        annotations = {
          summary = "{{ $value }} expected backup timers are inactive on {{ $labels.instance }}";
          description = "One or more declaratively expected backup timers are inactive while no deployment guard is active.";
          command = "systemctl list-units --type=timer --all | grep -E 'restic|pgbackrest|syncoid|sanoid'";
        };
      };

      "deployment-backup-timer-restoration-failed" = {
        type = "promql";
        alertname = "DeploymentBackupTimerRestorationFailed";
        expr = "nixos_deploy_backup_guard_last_restore_success == 0";
        for = "1m";
        severity = "critical";
        labels = { service = "nixos-deploy"; category = "backup"; };
        annotations = {
          summary = "Backup timer restoration failed after a NixOS deployment on {{ $labels.instance }}";
          description = "The guard retained its pause marker because one or more surviving timers did not become active or a guard drop-in remained.";
          command = "sudo nixos-deploy-backup-guard status";
        };
      };

      "deployment-backup-guard-monitoring-stale" = {
        type = "promql";
        alertname = "DeploymentBackupGuardMonitoringStale";
        expr = ''
          (time() - nixos_deploy_backup_guard_last_check_timestamp_seconds > 180)
          or on(instance)
          (
            node_systemd_unit_state{name="nixos-deploy-backup-guard-metrics.timer",state=~"active|activating|deactivating|failed|inactive"} == 1
            unless on(instance)
            nixos_deploy_backup_guard_last_check_timestamp_seconds
          )
        '';
        for = "5m";
        severity = "high";
        labels = { service = "nixos-deploy"; category = "monitoring"; };
        annotations = {
          summary = "NixOS deployment backup guard monitoring is stale on {{ $labels.instance }}";
          description = "Guard metrics have not updated for at least three minutes, so paused or inactive backup timers may be undetected.";
          command = "systemctl status nixos-deploy-backup-guard-metrics.timer";
        };
      };
    };
  };
}
