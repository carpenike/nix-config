# tqm package definition
# Based on https://github.com/autobrr/tqm

{ lib
, buildGoModule
, fetchFromGitHub
}:

buildGoModule rec {
  pname = "tqm";
  # renovate: depName=autobrr/tqm datasource=github-releases
  version = "1.19.0";

  src = fetchFromGitHub {
    owner = "autobrr";
    repo = "tqm";
    rev = "v${version}";
    hash = "sha256-bGvcZMKop5QTE84KichJ/vuhRTQ9YKEe/AANMV4wOGo=";
  };

  vendorHash = "sha256-IUAqY4w0Akm1lJJU5fZkVQpc5fWUx/88+hAinwZN3y4=";

  ldflags = [
    "-s"
    "-w"
    "-X main.version=${version}"
  ];

  # Skip tests - they try to create directories in /homeless-shelter during build
  doCheck = false;

  meta = with lib; {
    description = "Torrent qBittorrent Manager - Fast, lightweight qBittorrent automation";
    homepage = "https://github.com/autobrr/tqm";
    license = licenses.mit;
    maintainers = [ ];
    platforms = platforms.linux;
  };
}
