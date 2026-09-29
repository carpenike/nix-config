{ lib
, stdenv
, fetchurl
, fetchFromGitHub
, rustPlatform
, autoPatchelfHook
, makeWrapper
, pkg-config
, openssl
, zlib
, libsecret
, bash
, coreutils
, cacert
, python3
}:
let
  version = "1.139.1";
  commit = "04c0d99f4fb0d8afe6ce4f0c58e31e183ac3e4b1";
  runtime = stdenv.mkDerivation {
    pname = "vscode-agent-host-runtime";
    inherit version;
    src = fetchurl {
      url = "https://vscode.download.prss.microsoft.com/dbazure/download/stable/${commit}/vscode-server-linux-x64.tar.gz";
      hash = "sha256-4s41uMC5DPIX/u6Yc6GcHi7kFM8BpZidZ8h+DvhBaJQ=";
    };
    nativeBuildInputs = [ autoPatchelfHook makeWrapper ];
    buildInputs = [ stdenv.cc.cc.lib openssl zlib libsecret ];
    dontBuild = true;
    dontStrip = true;
    installPhase = ''
      runHook preInstall
      mkdir -p "$out/lib/vscode-agent-host" "$out/bin"
      # The standalone host uses the bundled SDKs, not desktop extension hosts.
      # In particular, MSAL's GUI extension would pull GTK/WebKit into a headless service.
      cp -a bin node node_modules out package.json product.json LICENSE "$out/lib/vscode-agent-host/"
      mkdir "$out/lib/vscode-agent-host/extensions"
      patchShebangs "$out/lib/vscode-agent-host/bin"
      makeWrapper "$out/lib/vscode-agent-host/bin/code-server" "$out/bin/code-server" \
        --prefix PATH : ${lib.makeBinPath [ bash coreutils ]} \
        --set-default NODE_EXTRA_CA_CERTS ${cacert}/etc/ssl/certs/ca-bundle.crt
      runHook postInstall
    '';
    doInstallCheck = true;
    nativeInstallCheckInputs = [ python3 ];
    installCheckPhase = ''
      runHook preInstallCheck
      "$out/lib/vscode-agent-host/node" --version
      python3 - "$out/lib/vscode-agent-host/product.json" <<'PY'
      import json, sys
      product = json.load(open(sys.argv[1]))
      assert product["commit"] == "${commit}", "Unexpected VS Code runtime commit"
      assert product["version"] == "${version}", "Unexpected VS Code runtime version"
      PY
      runHook postInstallCheck
    '';
    meta = {
      description = "Pinned upstream VS Code server runtime for the standalone Agent Host";
      homepage = "https://code.visualstudio.com/docs/agents/concepts/agent-host";
      license = lib.licenses.unfree;
      platforms = [ "x86_64-linux" ];
    };
  };
in
rustPlatform.buildRustPackage {
  pname = "vscode-agent-host";
  inherit version;
  src = fetchFromGitHub {
    owner = "microsoft";
    repo = "vscode";
    rev = commit;
    hash = "sha256-ik/S5+aczpBeJyo3RRRNYkFBP01e4Zi+8QqWtRnuYHU=";
  };
  cargoRoot = "cli";
  buildAndTestSubdir = "cli";
  cargoHash = "sha256-qubW1HgtP1NxoBL9SuPo0j4zJjuO7ylaZu8FUqJPEHQ=";

  # WORKAROUND (2026-09-29): The released CLI updates its server independently.
  # The upstream compile-time override disables that loop and fixes the backend.
  # Check: replace with an upstream immutable-runtime option when one exists.
  # Upstream: cli/src/{commands,tunnels}/agent_host.rs at the commit above.
  # See docs/workarounds.md and docs/vscode-agent-host.md.
  env = {
    VSCODE_CLI_OVERRIDE_SERVER_PATH = "${runtime}/bin/code-server";
    VSCODE_CLI_PRODUCT_JSON = "${runtime}/lib/vscode-agent-host/product.json";
  };

  nativeBuildInputs = [ pkg-config makeWrapper ];
  buildInputs = [ openssl zlib ];
  doCheck = false; # Untouched upstream source; the local runtime smoke test covers packaging.
  postInstall = ''
    wrapProgram "$out/bin/code" \
      --prefix PATH : ${lib.makeBinPath [ bash coreutils ]} \
      --set-default SSL_CERT_FILE ${cacert}/etc/ssl/certs/ca-bundle.crt
  '';
  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    export HOME="$PWD/cli-check-home"
    mkdir -m 0700 "$HOME"
    "$out/bin/code" --version | grep -F '${version}'
    "$out/bin/code" agent host --help > host-help
    for flag in --host --port --connection-token-file --server-data-dir --user-data-dir --new-instance --foreground; do
      grep -F -- "$flag" host-help
    done
    "$out/bin/code" agent ps --help | grep -F -- --json
    runHook postInstallCheck
  '';

  passthru = { inherit commit runtime; };
  meta = {
    description = "Standalone upstream VS Code Agent Host with an immutable native runtime";
    homepage = "https://code.visualstudio.com/docs/agents/concepts/agent-host";
    license = [ lib.licenses.mit lib.licenses.unfree ];
    platforms = [ "x86_64-linux" ];
    mainProgram = "code";
  };
}
