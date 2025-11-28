{ lib, python311Packages }:

python311Packages.buildPythonApplication rec {
  pname = "backup-list";
  version = "0.1.0";

  # Point to the single Python script
  src = ../scripts/backup-list.py;

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
    description = "List available Restic snapshots for all enabled backup services";
    longDescription = ''
      A CLI tool that discovers all enabled Restic backup services via SSH
      and lists their available snapshots. Supports filtering by service name
      or repository, JSON output for scripting, and detailed statistics.

      Features:
        - Runs locally, SSHs to remote host
        - Auto-discovers backup services from systemd
        - Lists snapshots from all repositories (NAS, R2, etc.)
        - Supports filtering by service or repository name
        - JSON output for scripting/automation
        - Rich formatted terminal output

      Examples:
        backup-list                       # List all snapshots
        backup-list --service sonarr      # Filter by service
        backup-list --repo nas-primary    # Filter by repository
        backup-list --json | jq           # JSON output
    '';
    license = licenses.mit;
    platforms = platforms.all;
    mainProgram = "backup-list";
  };
}
