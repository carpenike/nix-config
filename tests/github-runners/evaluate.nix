# Eval-time contract for Forge's self-hosted GitHub Actions runners
# (hosts/forge/services/github-runner.nix). Fails evaluation if any
# invariant breaks; the result is written as JSON by flake checks.
{ inputs }:
let
  inherit (inputs.nixpkgs) lib;
  c = inputs.self.nixosConfigurations.forge.config;
  expected = [ "atrium" "mcp" "network-config" "schoolhouse" "whiskey" ];
  privateRepos = {
    atrium = "https://github.com/carpenike/atrium";
    mcp = "https://github.com/carpenike/mcp";
    network-config = "https://github.com/carpenike/network-config";
    schoolhouse = "https://github.com/carpenike/schoolhouse";
    whiskey = "https://github.com/carpenike/whiskey-whiskey-whiskey";
  };
  runners = c.services.github-runners;
  units = lib.genAttrs expected (n: c.systemd.services."github-runner-${n}");
  sc = n: units.${n}.serviceConfig;
  users = map (n: (sc n).User) expected;
  allowed = n: (sc n).IPAddressAllow;
  isPrivateV4 = a: lib.any (p: lib.hasPrefix p a) [ "10." "192.168." "172.16." "100.64." "169.254." ];

  checks = {
    exactlyThePrivateRepos = lib.attrNames runners == expected
      && lib.all (n: runners.${n}.url == privateRepos.${n}) expected;
    noPublicNixConfigRunner = !(runners ? forge)
      && lib.all (n: runners.${n}.url != "https://github.com/carpenike/nix-config") expected;
    sharedSopsToken = lib.all (n: runners.${n}.tokenFile == "/run/secrets/github/runner-token") expected
      && c.sops.secrets."github/runner-token".owner == "root"
      && c.sops.secrets."github/runner-token".mode == "0400";
    ephemeralSingle = lib.all (n: runners.${n}.ephemeral && !(c.systemd.services ? "github-runner-${n}-1")) expected;
    distinctStaticUsers = lib.length (lib.unique users) == lib.length expected
      && lib.all
      (n: !(sc n).DynamicUser && (sc n).User == "github-runner-${n}"
        && (sc n).Group == "github-runner-${n}"
        && c.users.users."github-runner-${n}".isSystemUser)
      expected;
    labels = lib.all (n: lib.elem "nixos" runners.${n}.extraLabels && lib.elem n runners.${n}.extraLabels) expected;
    resourceLimits = lib.all
      (n: (sc n).Slice == "github-runners.slice"
        && (sc n) ? MemoryMax && (sc n) ? CPUQuota && (sc n).MemorySwapMax == "0"
        && (sc n).Nice == 10)
      expected
    && c.systemd.slices.github-runners.sliceConfig.MemoryMax == "4G";
    egressRestricted = lib.all
      (n: (sc n).IPAddressDeny == "any"
        && lib.elem "127.0.0.0/8" (allowed n)
        && !(lib.any (a: lib.hasInfix ":" a && a != "::1/128") (allowed n))
        && lib.all (a: !(isPrivateV4 a) || lib.elem a c.modules.services.github-runner.allowedAddresses) (allowed n))
      expected;
    hardening = lib.all
      (n: (sc n).ProtectSystem == "strict" && builtins.isBool (sc n).ProtectHome && (sc n).ProtectHome
        && (sc n).NoNewPrivileges && (sc n).PrivateTmp
        && lib.elem "-/run/secrets.d" (sc n).InaccessiblePaths
        && lib.elem "-/run/secrets/github/runner-token" (sc n).InaccessiblePaths)
      expected;
    onDiskWorkDirs = lib.all (n: runners.${n}.workDir == "/var/lib/github-runner-work/${n}") expected;
    # Jobs cannot read /etc/nix/nix.conf (its access-tokens !include is
    # inaccessible), so the client conf must carry the host's features.
    nixClientFeatures =
      let settings = c.modules.services.github-runner.nixClientSettings; in
      lib.splitString " " settings.experimental-features == c.nix.settings.experimental-features
      && lib.elem "flakes" c.nix.settings.experimental-features
      && lib.all (n: lib.hasSuffix "-github-runner-nix.conf" runners.${n}.extraEnvironment.NIX_USER_CONF_FILES) expected;
    caBundle = lib.all (n: runners.${n}.extraEnvironment.SSL_CERT_FILE == "/etc/ssl/certs/ca-certificates.crt") expected;
    opensslCli = lib.all (n: lib.elem "openssl" (map lib.getName runners.${n}.extraPackages)) expected;
    networkConfigHasNoRouterTooling = !(lib.any (p: lib.elem (lib.getName p) [ "openssh" "sshpass" "routeros" ])
      runners.network-config.extraPackages);
  };
  failed = lib.attrNames (lib.filterAttrs (_: ok: !ok) checks);
in
assert lib.assertMsg (failed == [ ]) "github-runners contract failed: ${lib.concatStringsSep ", " failed}";
checks
