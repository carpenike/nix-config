# qbit_manage package definition
# Based on https://github.com/StuffAnThings/qbit_manage

{ lib
, buildPythonApplication
, fetchFromGitHub
, requests
, pyyaml
, schedule
, pathvalidate
, humanize
}:

buildPythonApplication rec {
  pname = "qbit_manage";
  # renovate: depName=StuffAnThings/qbit_manage datasource=github-releases
  version = "4.6.3";

  src = fetchFromGitHub {
    owner = "StuffAnThings";
    repo = "qbit_manage";
    rev = "v${version}";
    hash = "sha256-cTxM3nHQQto7lpoNjShYcCbJCSYiwS9bKqw0DWAjw6A=";
  };

  propagatedBuildInputs = [
    requests
    pyyaml
    schedule
    pathvalidate
    humanize
  ];

  # Skip tests for now (they may require qBittorrent running)
  doCheck = false;

  meta = with lib; {
    description = "Comprehensive qBittorrent management tool with tracker-aware seeding rules";
    homepage = "https://github.com/StuffAnThings/qbit_manage";
    license = licenses.mit;
    maintainers = [ ];
    platforms = platforms.linux;
  };
}
