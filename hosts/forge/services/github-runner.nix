# hosts/forge/services/github-runner.nix
#
# GitHub Actions self-hosted runners on 'forge' for Ryan's PRIVATE repos,
# whose GitHub-hosted CI is blocked by the account spending limit.
# Self-hosted minutes are not billed.
#
# Public repos (nix-config itself) deliberately get NO runner here: anyone
# can open a PR against a public repo, and a self-hosted runner would run
# their code on Forge.
#
# Token: one fine-grained PAT (resource owner carpenike, repository access =
# exactly the repos below, permission "Administration: read and write"),
# stored in SOPS as github/runner-token (hosts/forge/secrets.nix). Adding a
# runner for another repo means adding that repo to the PAT's repository
# access first.
#
# Workflows target a runner with: runs-on: [self-hosted, nixos, <name>]
# After deployment, check each repo's Settings -> Actions -> Runners for
# forge-<name>.
#
# Resource budget (Forge: 31 GiB RAM, normally ~6 GiB available, zram swap
# near full; 16 cores):
#   - github-runners.slice caps ALL CI at 4G / 4 cores (400%), so even five
#     concurrent jobs cannot take more than ~2/3 of today's headroom.
#   - Per-runner MemoryMax sized from the job type (below); MemoryHigh sits
#     ~25% under it so a job is throttled and reclaimed before it is killed.
#   - MemorySwapMax=0: CI must never push Forge's services further into swap.
#   - CPUWeight/IOWeight 20 (services default to 100), Nice 10, batch CPU
#     scheduling and best-effort IO priority 7: CI yields under contention.
#   - Idle cost is ~30-80 MB per Runner.Listener, so all five stay on.
#   - Nix builds run in nix-daemon's cgroup, not the runner's; jobs ask the
#     daemon for max-jobs=1 / cores=2 (module nixBuild defaults).

{ config, lib, pkgs, ... }:

let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  serviceEnabled = config.modules.services.github-runner.enable or false;
  runners = config.modules.services.github-runner.runners;

  # Headless Chromium (Playwright's chromium-headless-shell) needs these on
  # top of nix-ld's defaults when it runs from the downloaded build.
  chromiumLibraries = with pkgs; [
    alsa-lib
    at-spi2-atk
    at-spi2-core
    atk
    cairo
    cups
    dbus
    expat
    fontconfig
    freetype
    glib
    libdrm
    libgbm
    libxkbcommon
    nspr
    nss
    pango
    xorg.libX11
    xorg.libXcomposite
    xorg.libXdamage
    xorg.libXext
    xorg.libXfixes
    xorg.libXrandr
    xorg.libxcb
  ];
in
{
  config = lib.mkMerge [
    {
      modules.services.github-runner = {
        enable = true;

        # Note: hardcoded path to avoid a circular dependency with
        # secrets.nix (which checks whether this service is enabled).
        tokenFile = "/run/secrets/github/runner-token";

        # Forge resolves through a LAN DNS server, which restrictNetwork would
        # otherwise refuse. Reuse the resolver list Forge already declares for
        # Atrium's egress policy instead of repeating an address here.
        allowedAddresses = config.services.atriumForge.whiskeyEgress.dnsAddresses;

        slice = {
          memoryMax = "4G";
          cpuQuota = "400%";
        };

        runners = {
          # Python (pip, ruff, mypy, pytest), a localhost conformance server,
          # and Nix package builds/flake checks.
          mcp = {
            url = "https://github.com/carpenike/mcp";
            extraPackages = with pkgs; [
              python312 # nix job's python3
              uv # creates the 3.12 venv the pip steps use
              gh # atrium-hermes-check.py fetches pinned sources with gh
            ];
            memoryHigh = "1536M";
            memoryMax = "2G";
          };

          # Mostly Nix builds/checks (heavy lifting happens in nix-daemon),
          # plus an npm build/test of the PWA.
          atrium = {
            url = "https://github.com/carpenike/atrium";
            extraPackages = with pkgs; [
              python3 # packaged-client receipt script
            ];
            memoryHigh = "1536M";
            memoryMax = "2G";
          };

          # uv + ruff/mypy/pytest on a small offline suite.
          schoolhouse = {
            url = "https://github.com/carpenike/schoolhouse";
            extraPackages = with pkgs; [ uv ];
            memoryHigh = "768M";
            memoryMax = "1G";
          };

          # Node: eslint/tsc/vitest, vite build, then Playwright Chromium.
          # The largest job, hence the largest share.
          whiskey = {
            url = "https://github.com/carpenike/whiskey-whiskey-whiskey";
            extraPackages = with pkgs; [
              python3 # node-gyp fallback if a prebuilt addon is unavailable
              gcc
            ];
            extraEnvironment = {
              FONTCONFIG_FILE = "${pkgs.makeFontsConf { fontDirectories = [ pkgs.dejavu_fonts ]; }}";
              # Playwright's host check runs ldd, which cannot see nix-ld's
              # libraries; the browser itself runs fine through nix-ld.
              PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS = "1";
            };
            nixLd.extraLibraries = chromiumLibraries;
            memoryHigh = "2560M";
            memoryMax = "3G";
          };

          # Router config: validation only (shellcheck + gitleaks). The runner
          # holds no router credentials and restrictNetwork refuses the LAN.
          network-config = {
            url = "https://github.com/carpenike/network-config";
            extraPackages = with pkgs; [ shellcheck ];
            memoryHigh = "384M";
            memoryMax = "512M";
            cpuQuota = "100%";
          };
        };
      };
    }

    (lib.mkIf serviceEnabled {
      # WORKAROUND (2026-09-25): GitHub rejects the EOL channel's runner.
      # Affects: Forge's Actions runners; unstable requires Node 24 only.
      # Upstream: https://github.com/actions/runner/releases/tag/v2.337.0
      # Check: Remove when stable supplies a supported runner and matching runtimes.
      modules.services.github-runner = {
        package = pkgs.unstable.github-runner;
        nodeRuntimes = [ "node24" ];
      };

      # One down-alert per runner unit.
      modules.alerting.rules = lib.mapAttrs'
        (name: _: lib.nameValuePair "github-runner-${name}-service-down"
          (forgeDefaults.mkSystemdServiceDownAlert
            "github-runner-${name}"
            "GitHubRunner${lib.concatMapStrings (w: lib.toUpper (lib.substring 0 1 w) + lib.substring 1 1000 w) (lib.splitString "-" name)}"
            "CI/CD self-hosted runner (${name})"))
        (lib.filterAttrs (_: r: r.enable) runners);
    })
  ];
}
