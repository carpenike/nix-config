{ pkgs }:
pkgs.runCommand "finance-signal-staging-runtime-tests"
{
  nativeBuildInputs = [ pkgs.python3 pkgs.ruff pkgs.shellcheck ];
  PYTHONDONTWRITEBYTECODE = "1";
  FINANCE_STAGING_RUNTIME = ../../hosts/forge/services/finance-signal/runtime.py;
}
  ''
    python3 ${./test-runtime.py}
    ruff check "$FINANCE_STAGING_RUNTIME" ${./test-runtime.py}
    ruff format --check "$FINANCE_STAGING_RUNTIME" ${./test-runtime.py}
    shellcheck ${./run.sh}
    touch "$out"
  ''
