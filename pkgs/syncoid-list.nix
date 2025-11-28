{ lib, python311Packages }:

python311Packages.buildPythonApplication rec {
  pname = "syncoid-list";
  version = "0.1.0";

  # Point to the single Python script
  src = ../scripts/syncoid-list.py;

  # Since this is a single script (not a proper Python package with setup.py),
  # we need to handle installation manually
  format = "other";

  propagatedBuildInputs = with python311Packages; [
    rich
    requests
  ];

  dontUnpack = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    install -D -m755 $src $out/bin/${pname}
    runHook postInstall
  '';

  meta = with lib; {
    description = "List Syncoid ZFS replication status for all configured datasets";
    longDescription = ''
      A CLI tool that queries Syncoid replication status from Prometheus metrics
      or directly from systemd units via SSH. Provides a dashboard view of all
      ZFS replication jobs with status, timestamps, and target information.

      Features:
        - Query Prometheus metrics (fast, default mode)
        - Query systemd directly via SSH (verify mode, slower but validates)
        - Filter by dataset name or target host
        - JSON output for scripting/automation
        - Rich formatted terminal output with status colors
        - Stale detection with configurable threshold

      Examples:
        syncoid-list                      # List all replications via Prometheus
        syncoid-list --dataset sonarr     # Filter by dataset name
        syncoid-list --target nas-1       # Filter by target host
        syncoid-list --verify             # Query systemd directly
        syncoid-list --json | jq          # JSON output
    '';
    license = licenses.mit;
    platforms = platforms.all;
    mainProgram = "syncoid-list";
  };
}
