{
  lib,
  pkgs,
  rustPlatform,
  fetchFromGitHub,
  nodePackages ? pkgs.nodePackages,
  ...
}:
let
  tailwindcss = nodePackages.tailwindcss;
in
rustPlatform.buildRustPackage rec {
  pname = "cooklang-cli";
  version = "0.18.2";

  src = fetchFromGitHub {
    owner = "cooklang";
    repo = "CookCLI";
    rev = "v${version}";
    hash = "sha256-uw1xwE7hIE00OADV9kOXR1/gKSzvleW1/5PwfhH4fvE=";
  };

  cargoHash = "sha256-Yxln5eKNXONGd4Hy9Ru9t92iqK9zcTSpzu2j75bc3fk=";

  nativeBuildInputs = [
    tailwindcss
    pkgs.perl
  ];

  # Generate the Tailwind CSS bundle used by the web UI before building.
  preBuild = ''
    tailwindcss -i static/css/input.css -o static/css/output.css --minify
  '';

  doCheck = false;

  meta = with lib; {
    description = "Cooklang CLI with embedded recipe web server";
    homepage = "https://github.com/cooklang/CookCLI";
    license = licenses.mit;
    mainProgram = "cook";
    maintainers = [];
    platforms = platforms.unix;
  };
}
