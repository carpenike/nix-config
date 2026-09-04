{
  description = "carpenike's Nix-Config";

  # Binary caches for faster builds
  nixConfig = {
    extra-substituters = [
      "https://nix-community.cachix.org"
      "https://cache.garnix.io"
      "https://carpenike.cachix.org"
    ];
    extra-trusted-public-keys = [
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      "cache.garnix.io:CTFPyKSLcx5RMJKfLo5EEPUObbA78b0YQ2DTCJXqr9g="
      "carpenike.cachix.org-1:96Z6GrfQJkkTr1f6g9z1JCGGG54CjqIRvnrupPlzEPQ="
    ];
  };

  inputs = {
    #################### Official NixOS and HM Package Sources ####################

    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable"; # also see 'unstable-packages' overlay at 'overlays/default.nix"

    # Actual Budget 26.7 compatibility pin. Keep independent from the moving
    # unstable input until nixos-25.11 provides Actual >= 26.7.0.
    actual-nixpkgs.url = "github:NixOS/nixpkgs/e2587caef70cea85dd97d7daab492899902dbf5d";

    # nixos-hardware - does not have a nixpkgs input, pure module flake
    hardware = {
      url = "github:nixos/nixos-hardware";
    };

    #################### Common Dependencies (for follows directives) ####################

    # Systems - shared system type definitions
    # Direct input allows other flakes to follow it, reducing lock file duplication
    systems.url = "github:nix-systems/default";

    # Flake-utils - common flake utility functions
    # Direct input allows dependent flakes to share one locked dependency.
    flake-utils = {
      url = "github:numtide/flake-utils";
      inputs.systems.follows = "systems";
    };

    # Flake-parts - Simplify Nix Flakes with the module system
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };

    #################### Core Modules ####################

    # home-manager - home user+dotfile manager
    # https://github.com/nix-community/home-manager
    home-manager = {
      url = "github:nix-community/home-manager/release-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    #################### Utilities ####################

    # Declarative partitioning and formatting
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # sops-nix - secrets with mozilla sops
    # https://github.com/Mic92/sops-nix
    sops-nix = {
      url = "github:mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # NixVim - Configure Neovim with Nix
    # https://github.com/nix-community/nixvim
    nixvim = {
      url = "github:nix-community/nixvim";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-parts.follows = "flake-parts";
      inputs.systems.follows = "systems";
    };

    # VSCode community extensions
    # https://github.com/nix-community/nix-vscode-extensions
    nix-vscode-extensions = {
      url = "github:nix-community/nix-vscode-extensions";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # VSCode Remote SSH server for NixOS hosts
    nixos-vscode-server = {
      url = "github:nix-community/nixos-vscode-server";
      inputs.flake-parts.follows = "flake-parts";
    };

    # Rust toolchain overlay
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Catppuccin - Soothing pastel theme for Nix
    # https://github.com/catppuccin/nix
    # v1.0.2 does not have a nixpkgs input to follow
    catppuccin = {
      url = "github:catppuccin/nix/v1.0.2";
    };

    # nix-darwin - nix modules for darwin (MacOS)
    # https://github.com/LnL7/nix-darwin
    nix-darwin = {
      url = "github:LnL7/nix-darwin/nix-darwin-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Impermanence - does not have a nixpkgs input, pure module flake
    impermanence = {
      url = "github:nix-community/impermanence";
    };

    # git-hooks.nix - Pre-commit hooks in Nix
    # https://github.com/cachix/git-hooks.nix
    git-hooks = {
      url = "github:cachix/git-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    #################### Personal Repositories ####################

    # Hermes Agent — persistent AI agent and messaging gateway
    # https://github.com/NousResearch/hermes-agent
    # WORKAROUND (2026-07-30, rebased 2026-08-16 onto v0.20.2): Pin Signal
    # REST/WebSocket support, the cold-store evaluation fix, and fixed-port
    # OAuth callback cleanup. Fork branch nix-config/v2026.8.16 =
    # upstream v2026.8.16 + PR #53696 + ported #72689 + OAuth listener fix.
    # Upstream: https://github.com/NousResearch/hermes-agent/pull/53696
    #           https://github.com/NousResearch/hermes-agent/pull/72689
    # Fork fix: https://github.com/carpenike/hermes-agent/commit/9dfd2fc325f60d24d349ad47a5cf571899cede3c
    # Check: Return upstream after both PRs and callback cleanup land.
    hermes-agent = {
      url = "github:carpenike/hermes-agent/9dfd2fc325f60d24d349ad47a5cf571899cede3c";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };

    # whiskey-whiskey-whiskey — Operation W.W.W. Command Center
    # Self-hosted React + Fastify + SQLite + MCP app served from one Node process.
    # https://github.com/carpenike/whiskey-whiskey-whiskey
    whiskey-whiskey-whiskey = {
      url = "github:carpenike/whiskey-whiskey-whiskey";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # replog — self-hosted workout / family fitness tracking
    # Go + SQLite + embedded SPA, WebAuthn passkey auth (no OIDC).
    # https://github.com/carpenike/replog
    replog = {
      url = "github:carpenike/replog";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # marginalia — cook log service ("lab notebook for cooking"). Node +
    # TypeScript + Fastify + SQLite + MCP, deploy-pattern twin of Whiskey.
    # Native PocketID OIDC + embedded OAuth AS; reads CookLang lineage
    # one-way (no dependency on Whiskey). https://github.com/carpenike/marginalia
    marginalia = {
      url = "github:carpenike/marginalia";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # ambit — half-day outings planner with a browser UI and MCP surface.
    # Native PocketID OIDC + embedded OAuth AS; durable state lives in the
    # shared forge PostgreSQL instance. https://github.com/carpenike/ambit
    ambit = {
      url = "github:carpenike/ambit";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # homelab-mcp — small MCP server bridging homelab APIs (cooklang +
    # gatus today) into tools Claude can call. Runs its own embedded
    # OAuth 2.1 Authorization Server (federating user login to
    # PocketID) so Claude's MCP custom-connector flow can complete
    # DCR + PKCE without depending on Cloudflare Access for SaaS
    # (which serves non-spec discovery field names Claude rejects).
    # See README in upstream repo for the full architecture / tool
    # registry pattern.
    # https://github.com/carpenike/mcp
    homelab-mcp = {
      url = "github:carpenike/mcp";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # schoolhouse — Schoology parent-account ingest + read-only MCP server
    # for the household's children. Two units over one Postgres schema:
    # a twice-daily scraper and a thin MCP reader that never fetches.
    # Loopback-only and intentionally unpublished — it serves three minors'
    # education records and has no authorization layer of its own.
    # https://github.com/carpenike/schoolhouse
    schoolhouse = {
      url = "github:carpenike/schoolhouse";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # lading — Amazon order + transaction ingest for the household ledger.
    # A daily scraper and a thin /healthz probe over one Postgres schema; the
    # amazon_* MCP tools live in homelab-mcp and read this store through a
    # readonly role. Split out of homelab-mcp deliberately: the credential it
    # holds can place orders and change shipping addresses, and a model that
    # retries a failing tool is how an Amazon account gets challenge-locked.
    #
    # PRIVATE repo. forge fetches it via the GitHub PAT in the
    # `nix/access-tokens` SOPS secret (already wired for Whiskey and
    # Marginalia). Add `carpenike/lading` to that fine-grained token's
    # repository access or the build will 404 on this input.
    # https://github.com/carpenike/lading
    lading = {
      url = "github:carpenike/lading";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # coachiq — RV-C / multi-protocol CANbus monitoring (FastAPI + React).
    # Hybrid Nix module (post-HOF-020): import nixosModules.default and
    # configure services.coachiq.*; package at packages.<system>.coachiq.
    # Consumed by the nixpi (RV Raspberry Pi) host.
    # https://github.com/carpenike/coachiq
    coachiq = {
      url = "github:carpenike/coachiq";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
    };
  };

  outputs =
    { flake-parts
    , ...
    } @inputs:
    let
      overlays = import ./overlays { inherit inputs; };
      mkSystemLib = import ./lib/mkSystem.nix { inherit inputs; inherit overlays; };

      # Aggregate DNS records from all hosts for centralized zone management
      aggregateDnsRecords = import ./lib/dns-aggregate.nix {
        lib = inputs.nixpkgs.lib;
      };
    in
    flake-parts.lib.mkFlake { inherit inputs; } ({ config, ... }: {
      systems = [
        "aarch64-darwin"
        "x86_64-linux"
        "aarch64-linux"
      ];
      imports = [
        inputs.git-hooks.flakeModule
        inputs.flake-parts.flakeModules.modules
        ./features
      ];

      # Per-system outputs (packages, devShells, formatter, checks)
      perSystem = { config, system, ... }:
        let
          # Use nixpkgs with our overlays applied
          pkgs = import inputs.nixpkgs {
            inherit system;
            overlays = builtins.attrValues overlays;
            config.allowUnfree = true;
          };

          # Import all custom packages
          allPackages = import ./pkgs { inherit pkgs inputs; };

          # Filter packages to only those available on the current system
          # This prevents errors when checking packages on Darwin that are Linux-only
          availablePackages = inputs.nixpkgs.lib.filterAttrs
            (_name: pkg:
              let
                # Check if package has meta.platforms defined
                hasPlatforms = pkg ? meta && pkg.meta ? platforms;
                # If no platforms specified, assume available everywhere
                # Otherwise check if current system is in the platforms list
                isAvailable = !hasPlatforms ||
                  builtins.elem system pkg.meta.platforms ||
                  # Also check for platform patterns like "x86_64-linux"
                  builtins.any (p: p == system) pkg.meta.platforms;
              in
              isAvailable
            )
            allPackages;
        in
        {
          # Pre-commit hooks configuration (git-hooks.nix)
          # See: https://github.com/cachix/git-hooks.nix
          pre-commit = {
            check.enable = true; # Adds a check to CI
            settings = {
              hooks = {
                # ===== Nix Formatting & Linting =====
                # Matches CI (nix fmt --check)
                nixpkgs-fmt.enable = true;

                statix = {
                  enable = true;
                  settings.config = "statix.toml";
                };
                deadnix = {
                  enable = true;
                  settings = {
                    # Don't flag standard NixOS module patterns like { config, lib, pkgs, ... }:
                    # These unused args are required for proper nixpkgs callPackage/module semantics
                    noLambdaPatternNames = true;
                  };
                };

                # ===== Shell Script Linting =====
                # Catches common shell scripting errors in backup-orchestrator.sh, etc.
                shellcheck.enable = true;

                # ===== Python Linting =====
                # Fast linting for scripts/ Python files (ruff is 10-100x faster than flake8)
                ruff.enable = true;
                # Python formatting (runs after ruff --fix)
                ruff-format.enable = true;

                # ===== Configuration File Validation =====
                yamllint = {
                  enable = true;
                  settings.configPath = ".github/lint/.yamllint.yaml";
                };
                check-json.enable = true;
                check-toml.enable = true;

                # ===== General File Hygiene =====
                trim-trailing-whitespace.enable = true;
                end-of-file-fixer.enable = true;

                # ===== Security =====
                # Detect secrets before they're committed
                gitleaks = {
                  enable = true;
                  name = "gitleaks";
                  entry = "${pkgs.gitleaks}/bin/gitleaks protect --staged --redact --verbose";
                  pass_filenames = false;
                };
              };

              # Global exclude patterns
              excludes = [
                "^tmp/" # Temporary/scratch files
                "^site/" # Generated mkdocs site
                "^result" # Nix build outputs
                "^pkgs/_sources/" # nvfetcher-generated files
              ];
            };
          };

          # Development shell for working on nix-config
          # Tools here are repo-specific; nix/git/home-manager should be system-wide
          devShells.default = pkgs.mkShell {
            packages = with pkgs; [
              # Nix linting & formatting (pinned to flake.lock)
              nixpkgs-fmt
              statix
              deadnix
              nil # Nix LSP for editor/AI diagnostics

              # Shell & Python linting (for scripts/)
              shellcheck # Shell script static analysis
              ruff # Fast Python linter (replaces flake8/pylint)

              # Pre-commit (Python CLI needed to run hooks from git-hooks.nix)
              pre-commit

              # Security scanning
              gitleaks # Detect hardcoded secrets

              # NixOS deployment & diff tools
              nvd # Diff NixOS generations
              nix-diff # Detailed derivation diffs
              nvfetcher # Update custom package sources
              nix-update # Fix package hashes
              nix-fast-build # Parallel evaluation and builds for CI

              # Nix store inspection & debugging
              nix-tree # TUI to inspect store paths and dependency trees
              nix-du # Disk usage breakdown for Nix store
              nix-index # Find which package provides a file (run nix-index first)
              nurl # Generate Nix fetcher calls from URLs

              # File search & manipulation (for AI assistants)
              fd # Fast file finder
              sd # Simpler sed for search-replace
              tree # Directory structure overview

              # Task runner
              go-task

              # Secrets management (only needed in this repo)
              age
              ssh-to-age
              sops

              # Documentation (mkdocs for this repo's docs/)
              python312Packages.mkdocs
              python312Packages.mkdocs-material
              python312Packages.mkdocs-material-extensions
              python312Packages.pymdown-extensions
              python312Packages.mkdocs-minify-plugin
            ] ++ lib.optionals pkgs.stdenv.isDarwin [
              # Required for some tools on Darwin
              libiconv
            ] ++ lib.optionals pkgs.stdenv.isLinux [
              # NixOS rebuild (for remote deployments from Linux)
              nixos-rebuild
            ];

            shellHook = ''
              ${config.pre-commit.installationScript}
              echo ""
              echo "nix-config devshell"
              echo "  task          - list available commands"
              echo "  mkdocs serve  - preview docs at http://127.0.0.1:8000"
              echo "  pre-commit hooks installed ✓"
            '';
          };

          # Code formatter (nix fmt)
          # Wraps nixpkgs-fmt to exclude nvfetcher-generated files which use
          # their own formatting style and would otherwise cause CI failures.
          #
          # nixpkgs-fmt has no native --exclude flag, and walking a directory
          # arg (e.g. `nix fmt -- --check .`) would silently include
          # pkgs/_sources/generated.nix. We therefore expand any directory
          # args to an explicit file list with the excluded paths removed.
          #
          # The excluded paths mirror the pre-commit `excludes` block in this
          # flake (^tmp/, ^site/, ^result, ^pkgs/_sources/) plus tooling dirs
          # (.direnv, .git) so local runs match CI behaviour.
          formatter = pkgs.writeShellScriptBin "nixpkgs-fmt" ''
            set -euo pipefail

            flags=()
            paths=()
            for arg in "$@"; do
              case "$arg" in
                -*) flags+=("$arg") ;;
                *)  paths+=("$arg") ;;
              esac
            done

            # Default to current directory when no path is given (matches
            # `nixpkgs-fmt`'s native behaviour).
            if [ ''${#paths[@]} -eq 0 ]; then
              paths=(".")
            fi

            files=()
            for p in "''${paths[@]}"; do
              if [ -d "$p" ]; then
                while IFS= read -r f; do
                  files+=("$f")
                done < <(${pkgs.findutils}/bin/find "$p" \
                  \( -type d \( \
                       -name _sources \
                    -o -name tmp \
                    -o -name site \
                    -o -name result \
                    -o -name .direnv \
                    -o -name .git \
                  \) -prune \) -o \
                  -type f -name '*.nix' -print)
              elif [ -f "$p" ]; then
                case "$p" in
                  */pkgs/_sources/*|pkgs/_sources/*) ;;  # nvfetcher-generated
                  */tmp/*|tmp/*) ;;
                  */site/*|site/*) ;;
                  */.direnv/*|.direnv/*) ;;
                  */.git/*|.git/*) ;;
                  *) files+=("$p") ;;
                esac
              fi
            done

            # No-op when nothing to format (avoids nixpkgs-fmt's "no input" error)
            if [ ''${#files[@]} -eq 0 ]; then
              exit 0
            fi

            exec ${pkgs.nixpkgs-fmt}/bin/nixpkgs-fmt "''${flags[@]}" "''${files[@]}"
          '';

          # Custom packages - available via 'nix build .#<name>'
          # Filtered to only packages available on the current system
          packages = availablePackages;

          # Checks for CI
          checks = {
            # Statix linter (uses statix.toml for configuration)
            statix = pkgs.runCommand "statix-check" { nativeBuildInputs = [ pkgs.statix ]; } ''
              cd ${./.}
              statix check . --config statix.toml || exit 1
              touch $out
            '';

            # Deadnix - find dead code
            # Exclude auto-generated files from nvfetcher
            deadnix = pkgs.runCommand "deadnix-check" { nativeBuildInputs = [ pkgs.deadnix ]; } ''
              deadnix --fail --exclude pkgs/_sources/generated.nix ${./.} || exit 1
              touch $out
            '';

            oci-image-pinning =
              let
                lib = inputs.nixpkgs.lib;
                images = lib.concatLists (lib.mapAttrsToList
                  (hostName: nixosConfiguration:
                    lib.mapAttrsToList
                      (unitName: container: {
                        inherit hostName unitName;
                        image = container.image or "";
                      })
                      (nixosConfiguration.config.virtualisation.oci-containers.containers or { }))
                  inputs.self.nixosConfigurations);
                unpinnedImages = lib.filter
                  (entry: builtins.match ".*@sha256:[0-9a-f]{64}" entry.image == null)
                  images;
                unpinnedDescription = lib.concatMapStringsSep "\n"
                  (entry: "${entry.hostName}/${entry.unitName}: ${entry.image}")
                  unpinnedImages;
              in
              assert lib.assertMsg (unpinnedImages == [ ]) ''
                All effective OCI images must end in a sha256 digest. Unpinned images:
                ${unpinnedDescription}
              '';
              pkgs.runCommand "oci-image-pinning-check" { } ''
                touch $out
              '';

            backup-phase0 =
              let
                lib = inputs.nixpkgs.lib;
                forge = inputs.self.nixosConfigurations.forge.config;
                affectedJobs = [
                  "music-assistant"
                  "service-actual"
                  "service-apprise"
                  "service-bichon"
                  "service-cooklang"
                  "service-cooklangFederation"
                  "service-esphome"
                  "service-grafana-oncall"
                  "service-home-assistant"
                  "service-netvisor"
                  "service-omada"
                  "service-plex"
                  "service-radarr"
                  "service-sabnzbd"
                  "service-tdarr"
                  "service-termix"
                  "service-tududi"
                ];
                jobIsProtected = jobName:
                  let
                    job = forge.modules.services.backup._internal.allJobs.${jobName};
                    repository = forge.modules.services.backup.repositories.${job.repository};
                    service = forge.systemd.services."restic-backup-${jobName}";
                  in
                  job.useSnapshots
                    && job.zfsDataset != null
                    && builtins.hasAttr "zfs-snapshot-${jobName}" forge.systemd.services
                    && (service.serviceConfig.AmbientCapabilities or [ ]) == [ "CAP_DAC_READ_SEARCH" ]
                    && (service.serviceConfig.CapabilityBoundingSet or [ ]) == [ "CAP_DAC_READ_SEARCH" ]
                    && builtins.elem "/etc:ro" (service.serviceConfig.TemporaryFileSystem or [ ])
                    && builtins.elem "-/etc/resolv.conf" (service.serviceConfig.BindReadOnlyPaths or [ ])
                    && builtins.elem (toString repository.passwordFile) (service.serviceConfig.BindReadOnlyPaths or [ ])
                    && lib.any (lib.hasPrefix "SSL_CERT_FILE=") (service.serviceConfig.Environment or [ ])
                    && service.serviceConfig.KillMode == "mixed"
                    && !(service.serviceConfig ? ExecStartPost)
                    && !(service.serviceConfig ? SuccessExitStatus);
                resultScript = forge.systemd.services.restic-backup-service-actual.script;
                snapshotModule = builtins.readFile ./modules/nixos/services/backup/snapshots.nix;
              in
              assert lib.all jobIsProtected affectedJobs;
              assert lib.hasInfix ''exit "$restic_exit"'' resultScript;
              assert lib.hasInfix "restic_backup_result" resultScript;
              assert lib.hasInfix "result_complete=1" resultScript;
              assert lib.hasInfix "result_partial=1" resultScript;
              assert lib.hasInfix "result_failed=1" resultScript;
              assert lib.hasInfix ''restic_pid=$!'' resultScript;
              assert lib.hasInfix ''kill -TERM "$restic_pid"'' resultScript;
              assert lib.hasInfix ''wait "$restic_pid"'' resultScript;
              assert !(lib.hasInfix "chown root:restic-backup" snapshotModule);
              assert !(lib.hasInfix "chmod g+rx" snapshotModule);
              pkgs.runCommand "backup-phase0-check" { nativeBuildInputs = [ pkgs.coreutils pkgs.gnugrep ]; } ''
                snapshot_destroy_line=$(grep -n 'zfs}/bin/zfs destroy "''${dataset}@''${snapshotName}"' ${./modules/nixos/services/backup/snapshots.nix} | tail -1 | cut -d: -f1)
                lock_release_line=$(grep -n 'rm -f "\$DATASET_LOCK"' ${./modules/nixos/services/backup/snapshots.nix} | tail -1 | cut -d: -f1)
                test -n "$snapshot_destroy_line"
                test -n "$lock_release_line"
                test "$lock_release_line" -gt "$snapshot_destroy_line"
                touch $out
              '';

            zfs-dataset-restart-trigger =
              let
                forge = inputs.self.nixosConfigurations.forge;
                triggersFor = cfg: cfg.config.systemd.services.zfs-service-datasets.restartTriggers;
                withOverride = mod: forge.extendModules { modules = [ mod ]; };

                baseTriggers = triggersFor forge;
                # A newly declared dataset must move the trigger (the issue #852 case).
                addedTriggers = triggersFor (withOverride {
                  modules.storage.datasets.services.restart-trigger-regression.mountpoint = "none";
                });
                # Changing a property the script consumes on an existing dataset
                # must also move the trigger.
                propertyTriggers = triggersFor (withOverride {
                  modules.storage.datasets.services.postgresql.properties."com.holthome:restart-trigger-regression" = "1";
                });
                # Changing metadata the script does NOT consume (protection policy
                # and rootOwnedReason are manifest/warning-only) must NOT move it,
                # or we would re-run the oneshot on every unrelated policy edit.
                metadataTriggers = triggersFor (withOverride {
                  modules.storage.datasets.services.postgresql.rootOwnedReason = "restart-trigger regression probe";
                });
              in
              assert builtins.length baseTriggers == 1;
              assert baseTriggers != addedTriggers;
              assert baseTriggers != propertyTriggers;
              assert baseTriggers == metadataTriggers;
              pkgs.runCommand "zfs-dataset-restart-trigger-check" { } ''
                touch $out
              '';

            # Fleet guard for the issue #852 failure mode: a RemainAfterExit
            # oneshot whose script varies with config but carries no
            # restartTriggers is silently not re-run on switch. This asserts no
            # NEW such unit appears. The baseline below is the set that predates
            # the guard; each is once-per-boot or internally idempotent (re-runs
            # gated on state), so a stale script cannot silently corrupt persisted
            # data the way a skipped ZFS dataset does. A new hazardous unit must
            # instead carry restartTriggers (see modules/nixos/storage/datasets.nix).
            reexec-oneshot-guard =
              let
                lib = inputs.nixpkgs.lib;
                forge = inputs.self.nixosConfigurations.forge.config;
                svcs = forge.systemd.services;
                truthy = v: (builtins.isBool v && v) || v == "yes" || v == "true";
                isHazard = n:
                  let u = svcs.${n}; in
                  (u.script or "") != ""
                    && truthy (u.serviceConfig.RemainAfterExit or false)
                    && (u.restartTriggers or [ ]) == [ ];
                hazardous = builtins.filter isHazard (builtins.attrNames svcs);

                allowedPrefixes = [
                  "preseed-" # first-boot data seeders, gated on empty data dir
                  "network-" # boot-time network setup
                  "podman-network-" # idempotent podman network creation
                  "postgresql-" # DB bootstrap, idempotent
                  "pgbackrest-" # backup stanza/repo init, idempotent
                  "restic-init-" # restic repo init, idempotent
                  "netvisor-" # env/oidc config regenerated from sops each boot
                ];
                allowedExact = [
                  "grafana-oncall-plugin-setup"
                  "notify-boot"
                  "paperless-env"
                  "peanut-config"
                  "podman-grafana-oncall-migration"
                  "policy-routing-main"
                  "searx-init"
                  "ups-inject-secrets"
                  "wireless-netdev"
                  "zfs-import-tank"
                  "zfs-sync-rpool"
                  "zfs-sync-tank"
                ];
                isAllowed = n:
                  builtins.elem n allowedExact
                    || lib.any (p: lib.hasPrefix p n) allowedPrefixes;
                unguarded = builtins.filter (n: !(isAllowed n)) hazardous;
              in
              assert lib.assertMsg (unguarded == [ ])
                "RemainAfterExit oneshot(s) with a script but no restartTriggers (issue #852): ${lib.concatStringsSep ", " unguarded}. Add restartTriggers, or if genuinely once-per-boot/idempotent add it to the baseline in flake.nix.";
              pkgs.runCommand "reexec-oneshot-guard-check" { } ''
                touch $out
              '';

            protection-manifest =
              let
                forge = inputs.self.nixosConfigurations.forge.config;
                manifest = forge.modules.storage.protection.manifest;
                rendered = builtins.fromJSON forge.environment.etc."homelab/protection-manifest.json".text;
                actual = manifest.datasets."tank/services/actual";
                homeAssistant = manifest.datasets."tank/services/home-assistant";
                lading = manifest.datasets."tank/services/lading";
                musicAssistant = manifest.datasets."tank/services/music-assistant";
                legacyDirectPreseed = forge.systemd.services.preseed-mealie;
                legacyFactoryMain = forge.systemd.services.podman-qbittorrent;
                legacyFactoryPreseed = forge.systemd.services.preseed-qbittorrent;
                onCallEngine = forge.systemd.services.podman-grafana-oncall-engine;
                onCallMigration = forge.systemd.services.podman-grafana-oncall-migration;
                postgresql = manifest.datasets."tank/services/postgresql";
                prometheus = manifest.datasets."tank/services/prometheus";
                signalApi = manifest.datasets."tank/services/signal-api";
                failClosedUnits = {
                  actual = "actual";
                  apprise = "podman-apprise";
                  autobrr = "podman-autobrr";
                  bazarr = "podman-bazarr";
                  bichon = "podman-bichon";
                  cooklang = "cooklang";
                  esphome = "podman-esphome";
                  "grafana-oncall" = "podman-grafana-oncall-redis";
                  "home-assistant" = "home-assistant";
                  "music-assistant" = "music-assistant";
                  netvisor = "podman-netvisor-server";
                  omada = "podman-omada";
                  pocketid = "pocket-id";
                  plex = "podman-plex";
                  prowlarr = "podman-prowlarr";
                  qui = "podman-qui";
                  radarr = "podman-radarr";
                  seerr = "podman-seerr";
                  sonarr = "podman-sonarr";
                  thelounge = "thelounge";
                  zigbee2mqtt = "zigbee2mqtt";
                  "zwave-js-ui" = "zwave-js-ui";
                };
                disposableServices = [
                  "enclosed"
                  "searxng"
                  "tracearr"
                ];
                snapshotBackupServices = [
                  "prowlarr"
                  "qui"
                  "sonarr"
                  "thelounge"
                ];
                ephemeralPaths = [
                  "tank/services/alertmanager"
                  "tank/services/cooklang-federation"
                  "tank/services/dispatcharr"
                  "tank/services/enclosed"
                  "tank/services/homepage"
                  "tank/services/kometa"
                  "tank/services/miniflux"
                  "tank/services/prometheus"
                  "tank/services/promtail"
                  "tank/services/redis"
                  "tank/services/recyclarr"
                  "tank/services/searxng"
                  "tank/services/tdarr-cache"
                  "tank/services/teslamate"
                  "tank/services/tracearr"
                  "tank/services/valhalla"
                  "tank/temp"
                  "tank/services"
                  "tank/services/worldmonitor"
                  "tank/services/go2rtc"
                  "rpool/temp"
                ];
                criticalServicePaths = [
                  "tank/services/bichon"
                  "tank/services/omada"
                  "tank/services/pocketid"
                  "tank/services/plex"
                  "tank/services/zigbee2mqtt"
                  "tank/services/zwave-js-ui"
                ];
                standardServicePaths = [
                  "tank/services/apprise"
                  "tank/services/autobrr"
                  "tank/services/bazarr"
                  "tank/services/cooklang"
                  "tank/services/esphome"
                  "tank/services/grafana-oncall"
                  "tank/services/music-assistant"
                  "tank/services/netvisor"
                  "tank/services/prowlarr"
                  "tank/services/qui"
                  "tank/services/radarr"
                  "tank/services/seerr"
                  "tank/services/sonarr"
                  "tank/services/thelounge"
                ];
              in
              assert manifest.schemaVersion == 1;
              assert manifest.summary.total >= 60;
              # 2026-09-04, 48 -> 50: copilot-api (new) and litellm (re-enabled)
              # both declare a `standard` protection policy.
              assert manifest.summary.classified == 50;
              assert manifest.summary.byClass == {
                critical = 10;
                ephemeral = 21;
                # 15 since 2026-08-17: lading gained a declared dataset. It
                # had been running on the impermanence-rolled-back root with
                # no dataset and no persistence entry, so its state was wiped
                # every boot and the manifest could not see it at all.
                # 17 since 2026-09-04: copilot-api (new) and litellm
                # (re-enabled) both declare `standard`.
                standard = 17;
                system = 2;
              };
              assert manifest.summary.unknownRepositories == [ ];
              assert builtins.hasAttr "rpool/safe/persist" manifest.datasets;
              # The system identity dataset: /persist carries the SSH host key
              # that IS forge's SOPS identity. The `system-persist-offsite`
              # Restic job closed its offsite gap on 2026-08-17, so this now
              # asserts full coverage. Recovering from that copy still needs
              # the offline PGP key to reach the Restic password and R2
              # credentials - see the comment on the job in
              # hosts/forge/infrastructure/storage.nix.
              assert manifest.datasets."rpool/safe/persist".missingRequiredTiers == [ ];
              # /home is deliberately still onsite-only. It is user data
              # rather than recovery-critical identity, and it is far larger
              # than /persist, so its offsite copy is a cost decision that has
              # not been made rather than an oversight.
              assert manifest.datasets."rpool/safe/home".missingRequiredTiers == [ "offsite-backup" ];
              assert actual.classification == "critical";
              # The household ledger. Every required tier is satisfied: the
              # `actual-offsite` Restic job to r2-offsite closed the offsite
              # gap on 2026-08-17, so this asserts full coverage rather than
              # codifying a known hole. If it starts failing, an offsite tier
              # regressed - restore it rather than relaxing the assertion.
              assert actual.missingRequiredTiers == [ ];
              assert homeAssistant.missingRequiredTiers == [ "offsite-backup" ];
              # lading holds rotating Costco/Sam's tokens and a live Amazon
              # cookie jar. The dataset itself is the assertion that matters:
              # without one, /var/lib/lading sits on the root dataset that
              # initrd rolls back to @blank every boot, and the manifest
              # cannot see the dataset to complain. Asserting its presence and
              # full tier coverage is what stops that regressing unnoticed.
              assert lading.classification == "standard";
              assert lading.missingRequiredTiers == [ ];
              # Deliberately true, unlike the other standard services - which
              # is exactly why lading is not in standardServicePaths below.
              # There is no preseed unit, so an empty dataset must be a legal
              # state: the units re-seed the warehouse tokens from sops and
              # re-login to Amazon. That path is expensive and challenge-prone,
              # not impossible.
              assert lading.policy.allowEmptyBootstrap;
              assert !(builtins.hasAttr "lading" failClosedUnits);
              assert musicAssistant.coverage.automatedRestore;
              assert builtins.all
                (name:
                  let
                    mainName = failClosedUnits.${name};
                    mainUnit = forge.systemd.services.${mainName};
                    preseedUnit = forge.systemd.services."preseed-${name}";
                  in
                  builtins.elem "preseed-${name}.service" mainUnit.after
                    && builtins.elem "preseed-${name}.service" mainUnit.requires
                    && builtins.elem "${mainName}.service" preseedUnit.before
                    && builtins.elem "storage-preseed.target" preseedUnit.wantedBy
                    && preseedUnit.environment.ALLOW_EMPTY_BOOTSTRAP == "false"
                    && pkgs.lib.hasInfix "Refusing to start ${name} with an empty data directory" preseedUnit.script)
                (builtins.attrNames failClosedUnits);
              assert builtins.all
                (name:
                  !(builtins.hasAttr "restic-backup-service-${name}" forge.systemd.timers)
                    && !(builtins.hasAttr "preseed-${name}" forge.systemd.services)
                    && !(builtins.hasAttr "tank/services/${name}" forge.modules.backup.sanoid.datasets))
                disposableServices;
              assert builtins.all
                (name:
                  let
                    serviceConfig = forge.systemd.services."restic-backup-service-${name}".serviceConfig;
                  in
                  serviceConfig.AmbientCapabilities == [ "CAP_DAC_READ_SEARCH" ]
                    && serviceConfig.CapabilityBoundingSet == [ "CAP_DAC_READ_SEARCH" ]
                    && serviceConfig.ReadOnlyPaths == [ "/var/lib/backup-snapshots/service-${name}" ])
                snapshotBackupServices;
              assert builtins.elem "podman-grafana-oncall-migration.service" onCallEngine.requires;
              assert builtins.elem "preseed-grafana-oncall.service" onCallMigration.requires;
              assert builtins.elem "preseed-grafana-oncall.service" onCallMigration.after;
              assert !(pkgs.lib.hasInfix "Refusing to start mealie with an empty data directory" legacyDirectPreseed.script);
              assert builtins.elem "preseed-qbittorrent.service" legacyFactoryMain.wants;
              assert !(builtins.elem "preseed-qbittorrent.service" legacyFactoryMain.requires);
              assert !(pkgs.lib.hasInfix "Refusing to start qbittorrent with an empty data directory" legacyFactoryPreseed.script);
              assert postgresql.coverage.pgBackRest;
              assert postgresql.missingRequiredTiers == [ "independent-restore" ];
              assert prometheus.classification == "ephemeral";
              assert prometheus.missingRequiredTiers == [ ];
              # signal-api holds the Signal bot's registration keys, which are
              # not reproducible from any other source, so it carries a second
              # Restic job to r2-offsite and is the only critical service with
              # every tier satisfied - hence its absence from
              # criticalServicePaths below, which asserts a missing offsite
              # tier. allowEmptyBootstrap is true so a fresh deployment can
              # come up account-less for the registration runbook; the
              # /v1/accounts Gatus check covers what that concedes.
              assert signalApi.classification == "critical";
              assert signalApi.missingRequiredTiers == [ ];
              assert signalApi.policy.allowEmptyBootstrap;
              assert !(builtins.hasAttr "signal-api" failClosedUnits);
              assert builtins.all
                (path:
                  manifest.datasets.${path}.classification == "ephemeral"
                    && manifest.datasets.${path}.missingRequiredTiers == [ ])
                ephemeralPaths;
              assert builtins.all
                (path:
                  manifest.datasets.${path}.classification == "critical"
                    && manifest.datasets.${path}.missingRequiredTiers == [ "offsite-backup" ])
                criticalServicePaths;
              assert builtins.all
                (path:
                  manifest.datasets.${path}.classification == "standard"
                    && !manifest.datasets.${path}.policy.allowEmptyBootstrap
                    && manifest.datasets.${path}.missingRequiredTiers == [ ])
                standardServicePaths;
              assert rendered == manifest;
              pkgs.runCommand "protection-manifest-check" { } ''
                touch $out
              '';
          } // pkgs.lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == "x86_64-linux") {
            deployment-backup-guard =
              let
                forge = inputs.self.nixosConfigurations.forge.config;
                guard = forge.modules.deploymentGuard._internal.guardCommand;
                metrics = forge.modules.deploymentGuard._internal.metricsCommand;
                expectedTimers = forge.modules.deploymentGuard._internal.expectedBackupTimers;
                snapshotDatasets = pkgs.lib.filterAttrs
                  (_name: dataset: dataset.autosnap)
                  forge.modules.backup.sanoid.datasets;
                enabledResticJobs = pkgs.lib.filterAttrs
                  (_name: job: job.enable)
                  forge.modules.services.backup._internal.allJobs;
                snapshotMetricsScript = forge.systemd.services.zfs-snapshot-metrics.script;
                pgBackRestMetricsScript = forge.systemd.services.pgbackrest-metrics.script;
                requiredAlerts = [
                  "deployment-backup-guard-abandoned"
                  "deployment-backup-guard-monitoring-stale"
                  "deployment-backup-guard-stale"
                  "deployment-backup-timer-restoration-failed"
                  "deployment-backup-timers-inactive"
                ];
                requiredFreshnessAlerts = [
                  "pgbackrest-metrics-stale"
                  "restic-backup-success-missing"
                  "zfs-snapshot-exporter-stale"
                  "zfs-snapshot-never-created"
                ];
              in
              # 124 -> 125 and 57 -> 58 below: beszel-hub's backup gained a
                # restic job (restic-backup-beszel.timer). Its declaration used to
                # go to the deprecated modules.backup.* namespace, which generates
                # nothing, so the service had no backup at all. These counts are
                # tripwires on the deployment guard's timer set -- a backup job
                # appearing or vanishing should force exactly this review.
                #
                # 2026-08-17, 125 -> 131 timers, 57 -> 58 snapshot datasets and
                # 58 -> 61 restic jobs. Six new timers, all intended:
                #   pgbackrest-restore-drill-repo{1,2}.timer  - the restore
                #     drills existed as services that nothing ever scheduled;
                #     these arm them.
                #   restic-backup-actual-offsite.timer        - Actual Budget
                #     to r2-offsite, closing the ledger's offsite gap.
                #   restic-backup-system-persist-offsite.timer - /persist (the
                #     SOPS identity) to r2-offsite.
                #   restic-backup-lading.timer                - lading's new
                #     dataset, which also brings the +1 snapshot dataset and
                #     syncoid-tank-services-lading.timer.
                # The drill timers land in this set on purpose: the guard
                # pauses them for a deploy and restores them after, which is
                # what should happen to a job that takes the pgBackRest
                # backup lock.
                #
                # 2026-09-04, 131 -> 135 timers, 58 -> 60 snapshot datasets and
                # 61 -> 63 restic jobs: copilot-api (new) and litellm (re-enabled,
                # off since 2026-06-01) each bring a restic job
                # (restic-backup-service-<name>.timer) and a replicated dataset
                # (syncoid-tank-services-<name>.timer).
              assert builtins.length expectedTimers == 135;
              assert builtins.elem "pgbackrest-incr-backup.timer" expectedTimers;
              assert builtins.elem "restic-backup-service-plex.timer" expectedTimers;
              assert builtins.elem "sanoid.timer" expectedTimers;
              assert builtins.elem "syncoid-tank-services-plex.timer" expectedTimers;
              assert forge.systemd.timers.nixos-deploy-backup-guard-metrics.wantedBy == [ "timers.target" ];
              assert builtins.all (name: builtins.hasAttr name forge.modules.alerting.rules) requiredAlerts;
              assert builtins.length (builtins.attrNames snapshotDatasets) == 60;
              assert !(builtins.hasAttr "tank/services" snapshotDatasets);
              assert builtins.length (builtins.attrNames enabledResticJobs) == 63;
              assert builtins.all (name: builtins.hasAttr name forge.modules.alerting.rules) requiredFreshnessAlerts;
              assert pkgs.lib.hasInfix "zfs_snapshot_dataset_info" snapshotMetricsScript;
              assert pkgs.lib.hasInfix "zfs_snapshot_latest_timestamp" snapshotMetricsScript;
              assert pkgs.lib.hasInfix "pgbackrest_scrape_timestamp_seconds" pgBackRestMetricsScript;
              assert pkgs.lib.hasInfix ".*/syncoid_replication_" forge.modules.alerting.rules.zfs-replication-exporter-stale.expr;
              assert !(pkgs.lib.hasInfix "syncoid-replication-info" forge.modules.alerting.rules.zfs-replication-exporter-stale.expr);
              assert pkgs.lib.hasInfix "node_systemd_unit_state" forge.modules.alerting.rules.deployment-backup-guard-monitoring-stale.expr;
              assert pkgs.lib.hasInfix "node_systemd_unit_state" forge.modules.alerting.rules.pgbackrest-metrics-stale.expr;
              assert pkgs.lib.hasInfix "node_systemd_unit_state" forge.modules.alerting.rules.zfs-snapshot-exporter-stale.expr;
              assert !(pkgs.lib.hasInfix "zfs_latest_snapshot_age_seconds" forge.modules.alerting.rules.zfs-snapshot-too-old.expr);
              pkgs.runCommand "deployment-backup-guard-check"
                {
                  nativeBuildInputs = [
                    pkgs.bash
                    pkgs.coreutils
                    pkgs.diffutils
                    pkgs.gnugrep
                    metrics
                  ];
                } ''
                ${pkgs.bash}/bin/bash ${./scripts/test-nixos-deploy-backup-guard.sh} \
                  ${pkgs.lib.getExe guard} \
                  ${pkgs.lib.getExe metrics}
                ${pkgs.bash}/bin/bash ${./scripts/test-nix-apply-guarded.sh} \
                  ${./scripts/nix-apply-guarded.sh}
                touch $out
              '';
          };
        };

      flake =
        let
          fishModules = {
            nixos = config.flake.modules.nixos.fish;
            darwin = config.flake.modules.darwin.fish;
            homeManager = config.flake.modules.homeManager.fish;
          };
          mkNixosSystem = args:
            mkSystemLib.mkNixosSystem (args // {
              extraModules = (args.extraModules or [ ]) ++ [ fishModules.nixos ];
              extraHomeModules = (args.extraHomeModules or [ ]) ++ [ fishModules.homeManager ];
            });
        in
        {
          #################### NixOS Configurations ####################
          #
          # Building configurations available through `just rebuild` or `nixos-rebuild --flake .#hostname`
          nixosConfigurations = {
            # Bootstrap deployment - uses minimal builder to avoid compatibility issues
            nixos-bootstrap = mkSystemLib.mkNixosBootstrapSystem "x86_64-linux" "nixos-bootstrap";
            # Parallels devlab - minimal dev environment
            rydev = mkNixosSystem {
              system = "aarch64-linux";
              hostname = "rydev";
            };
            # Luna - DNS/network infrastructure server
            luna = mkNixosSystem {
              system = "x86_64-linux";
              hostname = "luna";
            };
            # Forge - main homelab server (all categories)
            forge = mkNixosSystem {
              system = "x86_64-linux";
              hostname = "forge";
            };
            # NAS-0 - Primary bulk storage NAS (117TB) - not yet deployed
            nas-0 = mkNixosSystem {
              system = "x86_64-linux";
              hostname = "nas-0";
              # Storage services use native NixOS modules in the host config;
              # no custom service category is required.
            };
            # NAS-1 - Secondary NAS / Backup target - not yet deployed
            nas-1 = mkNixosSystem {
              system = "x86_64-linux";
              hostname = "nas-1";
            };
            # Raspberry Pi RV system
            nixpi = mkNixosSystem {
              system = "aarch64-linux";
              hostname = "nixpi";
            };
            # Flashable SD image for nixpi (512 MiB firmware so the kernel fits).
            # Build: nix build .#nixosConfigurations.nixpi-image.config.system.build.sdImage
            nixpi-image = mkNixosSystem {
              system = "aarch64-linux";
              hostname = "nixpi";
              extraModules = [ ./hosts/nixpi/sd-image.nix ];
            };
          };

          darwinConfigurations = {
            rymac = mkSystemLib.mkDarwinSystem {
              system = "aarch64-darwin";
              hostname = "rymac";
              extraModules = [ fishModules.darwin ];
              extraHomeModules = [ fishModules.homeManager ];
            };
          };

          # Aggregated DNS records from all hosts' Caddy virtual hosts
          # View with: nix eval .#allCaddyDnsRecords --raw
          allCaddyDnsRecords = aggregateDnsRecords (
            inputs.self.nixosConfigurations // inputs.self.darwinConfigurations
          );

          # Convenience output that aggregates the outputs for home, nixos.
          # Also used in ci to build targets generally.
          ciSystems =
            let
              nixos =
                inputs.nixpkgs.lib.genAttrs
                  (builtins.attrNames inputs.self.nixosConfigurations)
                  (attr: inputs.self.nixosConfigurations.${attr}.config.system.build.toplevel);
              darwin =
                inputs.nixpkgs.lib.genAttrs
                  (builtins.attrNames inputs.self.darwinConfigurations)
                  (attr: inputs.self.darwinConfigurations.${attr}.system);
            in
            nixos // darwin;
        };
    });
}
