{ lib, python311Packages }:

python311Packages.buildPythonApplication rec {
  pname = "backup-status";
  version = "0.1.0";

  # Point to the single Python script
  src = ../scripts/backup-status.py;

  # Since this is a single script (not a proper Python package with setup.py),
  # we need to handle installation manually
  format = "other";

  propagatedBuildInputs = with python311Packages; [
    requests
    rich
  ];

  dontUnpack = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    install -D -m755 $src $out/bin/${pname}
    runHook postInstall
  '';

  meta = with lib; {
    description = "A CLI dashboard for monitoring backup status via Prometheus";
    license = licenses.unfree;
    maintainers = [ ];
  };
}
