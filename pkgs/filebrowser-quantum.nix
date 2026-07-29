{ fetchurl, lib, stdenvNoCC, upx }:

stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "filebrowser-quantum";
  version = "1.5.0-stable";

  src = fetchurl {
    url = "https://github.com/gtsteffaniak/filebrowser/releases/download/v${finalAttrs.version}/linux-amd64-filebrowser";
    hash = "sha256-jVHRcY1XbSLnPh9BpRlLRR0VLdqw35dpfKvoOc9ZUk4=";
  };

  dontUnpack = true;
  nativeBuildInputs = [ upx ];

  installPhase = ''
    runHook preInstall
    install -Dm755 "$src" "$out/bin/filebrowser-quantum"
    upx -d "$out/bin/filebrowser-quantum"
    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    version_output=$("$out/bin/filebrowser-quantum" version 2>&1 || true)
    printf '%s\n' "$version_output"
    printf '%s\n' "$version_output" | grep -F "v${finalAttrs.version}"
    runHook postInstallCheck
  '';

  meta = {
    description = "Modern web-based file manager";
    homepage = "https://filebrowserquantum.com";
    license = lib.licenses.asl20;
    mainProgram = "filebrowser-quantum";
    platforms = [ "x86_64-linux" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
})
