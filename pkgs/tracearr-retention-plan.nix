{ pkgs, lib, ... }:

pkgs.writeShellApplication {
  name = "tracearr-retention-plan";

  runtimeInputs = with pkgs; [
    jq
    postgresql_17
  ];

  text = builtins.readFile ./tracearr-retention-plan.sh;

  meta = with lib; {
    description = "Generate a read-only Tracearr TimescaleDB retention plan";
    longDescription = ''
      Builds an authoritative JSON plan for catching up Tracearr's failed
      TimescaleDB retention policy in bounded batches. The planner derives the
      live retention interval, selects chunks with show_chunks, records exact
      relation identities and ranges, and runs with PostgreSQL transaction
      writes disabled.
    '';
    license = licenses.mit;
    platforms = platforms.linux;
    mainProgram = "tracearr-retention-plan";
  };
}
