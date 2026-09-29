{ pkgs, package }:
pkgs.runCommand "vscode-agent-host-${package.version}-smoke"
{
  nativeBuildInputs = [ pkgs.python3 pkgs.bashInteractive pkgs.coreutils pkgs.git ];
  AGENT_HOST_TEST_LINKER = pkgs.stdenv.cc.bintools.dynamicLinker;
}
  ''
    export PYTHONDONTWRITEBYTECODE=1
    python3 ${./smoke.py} \
      ${package}/bin/code \
      ${package.runtime}/lib/vscode-agent-host/node \
      ${./protocol-smoke.mjs} \
      ${../../modules/nixos/services/vscode-agent-host} \
      ${pkgs.bashInteractive}/bin/bash
    printf '%s\n' 'Authenticated real-runtime smoke passed (no provider login/inference)' > "$out"
  ''
