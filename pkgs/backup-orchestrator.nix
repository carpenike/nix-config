{ pkgs, lib, ... }:

pkgs.writeShellApplication {
  name = "backup-orchestrator";

  runtimeInputs = with pkgs; [
    coreutils
    systemd
    gawk
    gnugrep
    util-linux  # for bash associative arrays
  ];

  text = builtins.readFile ./backup-orchestrator.sh;

  meta = with lib; {
    description = "Pre-deployment backup orchestrator for NixOS homelab";
    longDescription = ''
      Orchestrates all backup systems (Sanoid, Syncoid, Restic, pgBackRest)
      before major deployments. Provides stage-based execution with progress
      tracking, timeout handling, and failure aggregation.

      Stages:
        0. Pre-flight checks (disk space validation)
        1. ZFS snapshots (Sanoid)
        2. ZFS replication (Syncoid - parallel)
        3a. PostgreSQL backup (pgBackRest - sequential)
        3b. Application backups (Restic - limited parallel)
        4. Verification and reporting

      Exit codes:
        0 = All backups completed successfully
        1 = Partial failure (<50% failure rate) - acceptable
        2 = Critical failure (>50% failure rate or pre-flight failed)
    '';
    license = licenses.mit;
    platforms = platforms.linux;
    mainProgram = "backup-orchestrator";
  };
}
