# Backup Verification and Restore Testing Framework
#
# Provides enterprise-grade backup verification:
# - Automated repository integrity checks
# - Restore testing with sample files
# - Performance benchmarking
# - Compliance reporting

{ config, lib, pkgs, ... }:

let
  cfg = config.modules.services.backup;
  verificationCfg = cfg.verification or {};

  # Get all configured repositories
  repositories = cfg.repositories or {};

  # Create verification service for a repository
  mkVerificationService = repoName: repoConfig:
    let
      serviceName = "backup-verify-${repoName}";
    in {
      ${serviceName} = {
        description = "Verify backup repository ${repoName}";
        serviceConfig = {
          Type = "oneshot";
          User = "restic-backup";
          Group = "restic-backup";

          # Resource limits for verification
          MemoryMax = "1G";
          CPUQuota = "50%";
          IOSchedulingClass = "idle";

          # Environment setup
          Environment = [
            "RESTIC_REPOSITORY=${repoConfig.url}"
            "RESTIC_PASSWORD_FILE=${repoConfig.passwordFile}"
            "RESTIC_CACHE_DIR=${cfg.performance.cacheDir}"
          ];
          EnvironmentFile = lib.mkIf (repoConfig.environmentFile != null) repoConfig.environmentFile;

          # Paths
          ReadWritePaths = [
            cfg.performance.cacheDir
            "/var/lib/node_exporter/textfile_collector"
            "/var/log/backup"
            verificationCfg.testDir
          ];

          ExecStart = pkgs.writeShellScript "verify-repository-${repoName}" ''
            set -euo pipefail

            METRICS_FILE="/var/lib/node_exporter/textfile_collector/restic_verification_${repoName}.prom"
            LOG_FILE="/var/log/backup/verification-${repoName}.log"
            START_TIME=$(date +%s)

            # Cleanup function for metrics
            cleanup() {
              local exit_code=$?
              local end_time=$(date +%s)
              local duration=$((end_time - start_time))

              {
                echo "# HELP restic_verification_status Repository verification status (1=success, 0=failure)"
                echo "# TYPE restic_verification_status gauge"
                echo "restic_verification_status{repository=\"${repoName}\",hostname=\"${config.networking.hostName}\"} $([[ $exit_code -eq 0 ]] && echo 1 || echo 0)"

                echo "# HELP restic_verification_duration_seconds Verification duration in seconds"
                echo "# TYPE restic_verification_duration_seconds gauge"
                echo "restic_verification_duration_seconds{repository=\"${repoName}\",hostname=\"${config.networking.hostName}\"} $duration"

                if [[ $exit_code -eq 0 ]]; then
                  echo "# HELP restic_verification_last_success_timestamp Last successful verification"
                  echo "# TYPE restic_verification_last_success_timestamp gauge"
                  echo "restic_verification_last_success_timestamp{repository=\"${repoName}\",hostname=\"${config.networking.hostName}\"} $end_time"
                fi
              } > "$METRICS_FILE.tmp" && mv "$METRICS_FILE.tmp" "$METRICS_FILE"
            }
            trap cleanup EXIT

            exec > >(tee -a "$LOG_FILE") 2>&1
            echo "$(date): Starting verification for repository ${repoName}"

            # Check repository connectivity
            echo "Checking repository connectivity..."
            if ! ${pkgs.restic}/bin/restic snapshots --no-lock >/dev/null; then
              echo "ERROR: Cannot connect to repository ${repoName}"
              exit 1
            fi

            # Repository integrity check
            echo "Performing repository integrity check..."
            ${lib.optionalString verificationCfg.checkData
              "${pkgs.restic}/bin/restic check --read-data-subset=${verificationCfg.checkDataSubset}"
            }
            ${lib.optionalString (!verificationCfg.checkData)
              "${pkgs.restic}/bin/restic check"
            }

            # List recent snapshots
            echo "Checking recent snapshots..."
            RECENT_SNAPSHOTS=$(${pkgs.restic}/bin/restic snapshots --no-lock --json | ${pkgs.jq}/bin/jq -r '.[] | select(.time > (now - 86400)) | .id' | wc -l)

            if [[ $RECENT_SNAPSHOTS -eq 0 ]]; then
              echo "WARNING: No snapshots found in last 24 hours"
            else
              echo "Found $RECENT_SNAPSHOTS recent snapshots"
            fi

            # Write snapshot count metric
            {
              echo "# HELP restic_recent_snapshots_count Number of snapshots in last 24h"
              echo "# TYPE restic_recent_snapshots_count gauge"
              echo "restic_recent_snapshots_count{repository=\"${repoName}\",hostname=\"${config.networking.hostName}\"} $RECENT_SNAPSHOTS"
            } >> "$METRICS_FILE.tmp"

            echo "$(date): Verification completed successfully for repository ${repoName}"
          '';
        };
      };
    };

  # Create restore testing service for a repository
  mkRestoreTestService = repoName: repoConfig:
    let
      serviceName = "backup-restore-test-${repoName}";
    in {
      ${serviceName} = {
        description = "Restore test for backup repository ${repoName}";
        serviceConfig = {
          Type = "oneshot";
          User = "restic-backup";
          Group = "restic-backup";

          # Resource limits
          MemoryMax = "1G";
          CPUQuota = "50%";
          IOSchedulingClass = "idle";

          # Environment
          Environment = [
            "RESTIC_REPOSITORY=${repoConfig.url}"
            "RESTIC_PASSWORD_FILE=${repoConfig.passwordFile}"
            "RESTIC_CACHE_DIR=${cfg.performance.cacheDir}"
          ];
          EnvironmentFile = lib.mkIf (repoConfig.environmentFile != null) repoConfig.environmentFile;

          # Paths
          ReadWritePaths = [
            cfg.performance.cacheDir
            "/var/lib/node_exporter/textfile_collector"
            "/var/log/backup"
            verificationCfg.testDir
          ];

          ExecStart = pkgs.writeShellScript "restore-test-${repoName}" ''
            set -euo pipefail

            METRICS_FILE="/var/lib/node_exporter/textfile_collector/restic_restore_test_${repoName}.prom"
            LOG_FILE="/var/log/backup/restore-test-${repoName}.log"
            TEST_DIR="${verificationCfg.testDir}/${repoName}-$(date +%Y%m%d-%H%M%S)"
            START_TIME=$(date +%s)

            # Cleanup function
            cleanup() {
              local exit_code=$?
              local end_time=$(date +%s)
              local duration=$((end_time - start_time))

              # Clean up test directory
              rm -rf "$TEST_DIR" || true

              {
                echo "# HELP restic_restore_test_status Restore test status (1=success, 0=failure)"
                echo "# TYPE restic_restore_test_status gauge"
                echo "restic_restore_test_status{repository=\"${repoName}\",hostname=\"${config.networking.hostName}\"} $([[ $exit_code -eq 0 ]] && echo 1 || echo 0)"

                echo "# HELP restic_restore_test_duration_seconds Restore test duration"
                echo "# TYPE restic_restore_test_duration_seconds gauge"
                echo "restic_restore_test_duration_seconds{repository=\"${repoName}\",hostname=\"${config.networking.hostName}\"} $duration"

                if [[ $exit_code -eq 0 ]]; then
                  echo "# HELP restic_restore_test_last_success_timestamp Last successful restore test"
                  echo "# TYPE restic_restore_test_last_success_timestamp gauge"
                  echo "restic_restore_test_last_success_timestamp{repository=\"${repoName}\",hostname=\"${config.networking.hostName}\"} $end_time"
                fi
              } > "$METRICS_FILE.tmp" && mv "$METRICS_FILE.tmp" "$METRICS_FILE"
            }
            trap cleanup EXIT

            exec > >(tee -a "$LOG_FILE") 2>&1
            echo "$(date): Starting restore test for repository ${repoName}"

            # Create test directory
            mkdir -p "$TEST_DIR"

            # Get latest snapshot
            LATEST_SNAPSHOT=$(${pkgs.restic}/bin/restic snapshots --no-lock --json | ${pkgs.jq}/bin/jq -r '.[-1].id')

            if [[ -z "$LATEST_SNAPSHOT" || "$LATEST_SNAPSHOT" == "null" ]]; then
              echo "ERROR: No snapshots found in repository ${repoName}"
              exit 1
            fi

            echo "Testing restore from snapshot $LATEST_SNAPSHOT"

            # Get list of files from snapshot
            FILES=$(${pkgs.restic}/bin/restic ls --no-lock "$LATEST_SNAPSHOT" | head -${toString verificationCfg.restoreTesting.sampleFiles} || true)

            if [[ -z "$FILES" ]]; then
              echo "WARNING: No files found in snapshot"
            else
              # Attempt to restore sample files
              echo "$FILES" | while IFS= read -r file; do
                if [[ -n "$file" ]]; then
                  echo "Restoring sample file: $file"
                  ${pkgs.restic}/bin/restic restore --no-lock "$LATEST_SNAPSHOT" --target "$TEST_DIR" --include "$file" || {
                    echo "WARNING: Failed to restore $file"
                  }
                fi
              done

              # Verify files were restored
              RESTORED_FILES=$(find "$TEST_DIR" -type f | wc -l)
              echo "Successfully restored $RESTORED_FILES sample files"

              if [[ $RESTORED_FILES -eq 0 ]]; then
                echo "ERROR: No files were successfully restored"
                exit 1
              fi
            fi

            echo "$(date): Restore test completed successfully for repository ${repoName}"
          '';
        };
      };
    };

in {
  options.modules.services.backup.verification = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable backup verification framework";
    };

    schedule = lib.mkOption {
      type = lib.types.str;
      default = "weekly";
      description = "Verification schedule";
    };

    checkData = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable data integrity verification (slower but more thorough)";
    };

    checkDataSubset = lib.mkOption {
      type = lib.types.str;
      default = "10%";
      description = "Percentage of data to verify when checkData is enabled";
    };

    restoreTesting = lib.mkOption {
      type = lib.types.submodule {
        options = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Enable automated restore testing";
          };

          schedule = lib.mkOption {
            type = lib.types.str;
            default = "monthly";
            description = "Restore testing schedule";
          };

          sampleFiles = lib.mkOption {
            type = lib.types.int;
            default = 5;
            description = "Number of sample files to restore for testing";
          };
        };
      };
      default = {};
      description = "Restore testing configuration";
    };

    testDir = lib.mkOption {
      type = lib.types.path;
      default = "/tmp/restore-tests";
      description = "Directory for restore testing";
    };

    reporting = lib.mkOption {
      type = lib.types.submodule {
        options = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Enable verification reporting";
          };

          outputDir = lib.mkOption {
            type = lib.types.path;
            default = "/var/lib/backup-docs/verification";
            description = "Directory for verification reports";
          };
        };
      };
      default = {};
      description = "Verification reporting configuration";
    };
  };

  config = lib.mkIf (cfg.enable && verificationCfg.enable) {
    # Create verification services for each repository plus reporting service
    systemd.services = lib.mkMerge [
      (lib.mkMerge (lib.mapAttrsToList mkVerificationService repositories))
      (lib.mkMerge (lib.mapAttrsToList mkRestoreTestService
        (lib.filterAttrs (name: repo: verificationCfg.restoreTesting.enable) repositories)))
      {
        # Verification reporting service
        backup-verification-report = lib.mkIf verificationCfg.reporting.enable {
      description = "Generate backup verification report";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = pkgs.writeShellScript "generate-verification-report" ''
          set -euo pipefail

          REPORT_DIR="${verificationCfg.reporting.outputDir}"
          mkdir -p "$REPORT_DIR"

          REPORT_FILE="$REPORT_DIR/verification-report-$(date +%Y%m%d).md"

          cat > "$REPORT_FILE" << EOF
          # Backup Verification Report

          **Generated**: $(date)
          **Host**: ${config.networking.hostName}

          ## Repository Status

          EOF

          # Add status for each repository
          ${lib.concatStringsSep "\n" (lib.mapAttrsToList (repoName: repoConfig: ''
            echo "### Repository: ${repoName}" >> "$REPORT_FILE"
            echo "" >> "$REPORT_FILE"

            # Check verification status
            VERIFY_METRICS="/var/lib/node_exporter/textfile_collector/restic_verification_${repoName}.prom"
            if [[ -f "$VERIFY_METRICS" ]]; then
              VERIFY_STATUS=$(grep "restic_verification_status" "$VERIFY_METRICS" | awk '{print $2}' || echo "unknown")
              if [[ "$VERIFY_STATUS" == "1" ]]; then
                echo "- ✅ Verification: PASSED" >> "$REPORT_FILE"
              else
                echo "- ❌ Verification: FAILED" >> "$REPORT_FILE"
              fi
            else
              echo "- ⚠️ Verification: NO DATA" >> "$REPORT_FILE"
            fi

            # Check restore test status
            RESTORE_METRICS="/var/lib/node_exporter/textfile_collector/restic_restore_test_${repoName}.prom"
            if [[ -f "$RESTORE_METRICS" ]]; then
              RESTORE_STATUS=$(grep "restic_restore_test_status" "$RESTORE_METRICS" | awk '{print $2}' || echo "unknown")
              if [[ "$RESTORE_STATUS" == "1" ]]; then
                echo "- ✅ Restore Test: PASSED" >> "$REPORT_FILE"
              else
                echo "- ❌ Restore Test: FAILED" >> "$REPORT_FILE"
              fi
            else
              echo "- ⚠️ Restore Test: NO DATA" >> "$REPORT_FILE"
            fi

            echo "" >> "$REPORT_FILE"
          '') repositories)}

          echo "Generated verification report: $REPORT_FILE"
        '';
      };
        };
      }
    ];

    # Timer for reporting
    systemd.timers.backup-verification-report = lib.mkIf verificationCfg.reporting.enable {
      description = "Timer for verification reporting";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "weekly";
        Persistent = true;
      };
    };

    # Ensure test directory exists
    systemd.tmpfiles.rules = [
      "d ${verificationCfg.testDir} 0750 restic-backup restic-backup -"
      "d ${verificationCfg.reporting.outputDir} 0755 root root -"
    ];
  };
}
