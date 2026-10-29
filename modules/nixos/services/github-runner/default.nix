# GitHub Actions self-hosted runners (multi-repo)
#
# Wraps the native NixOS module (services.github-runners, ADR-005: native
# services over containers) with homelab-specific defaults:
#
# - One runner per repository. Personal accounts (carpenike) cannot register
#   org-level runners, so every repository gets its own repo-scoped runner.
# - One shared token file (a fine-grained PAT with "Administration:
#   read/write" on every listed repository). Only the root-privileged
#   ExecStartPre (`+` prefix upstream) reads it; the job user never can.
# - Ephemeral, single instance, its own static system user and work
#   directory per runner, so jobs from one repository cannot read another
#   repository's checkout, caches or credentials.
# - Resource fencing: every runner sits in `github-runners.slice` (a shared
#   ceiling for all CI) and has its own MemoryHigh/MemoryMax/CPUQuota, a
#   lower CPU/IO weight, Nice and no swap.
# - Egress fencing: IPAddressDeny=any plus an allow-list of public IPv4,
#   loopback and explicitly allowed addresses (e.g. the resolver). LAN, CGNAT,
#   link-local, container bridges and all non-loopback IPv6 are refused.
# - Optional nix-ld inside the runner's mount namespace only, so prebuilt
#   toolchains downloaded by setup-node / setup-uv / pip / npm can run without
#   changing the host's /lib64 stub loader.
#
# Usage:
#   modules.services.github-runner = {
#     enable = true;
#     tokenFile = "/run/secrets/github/runner-token";
#     runners.myrepo = {
#       url = "https://github.com/carpenike/myrepo";
#       extraPackages = [ pkgs.uv ];
#     };
#   };
#
# Workflows target a runner with `runs-on: [self-hosted, nixos, <name>]`.
{ config, lib, pkgs, mylib, ... }:

let
  cfg = config.modules.services.github-runner;

  # Import shared types for standard submodules
  sharedTypes = mylib.types;

  enabledRunners = lib.filterAttrs (_: r: r.enable) cfg.runners;

  # Public IPv4 space: 0.0.0.0/0 minus 0/8, 10/8, 100.64/10 (CGNAT/Tailscale),
  # 127/8, 169.254/16, 172.16/12, 192.0.0/24, 192.168/16, 198.18/15,
  # 224/4 and 240/4. systemd's IPAddressAllow= has no "except", so the
  # complement is spelled out. Generated with Python's ipaddress module.
  publicIPv4 = [
    "1.0.0.0/8"
    "2.0.0.0/7"
    "4.0.0.0/6"
    "8.0.0.0/7"
    "11.0.0.0/8"
    "12.0.0.0/6"
    "16.0.0.0/4"
    "32.0.0.0/3"
    "64.0.0.0/3"
    "96.0.0.0/6"
    "100.0.0.0/10"
    "100.128.0.0/9"
    "101.0.0.0/8"
    "102.0.0.0/7"
    "104.0.0.0/5"
    "112.0.0.0/5"
    "120.0.0.0/6"
    "124.0.0.0/7"
    "126.0.0.0/8"
    "128.0.0.0/3"
    "160.0.0.0/5"
    "168.0.0.0/8"
    "169.0.0.0/9"
    "169.128.0.0/10"
    "169.192.0.0/11"
    "169.224.0.0/12"
    "169.240.0.0/13"
    "169.248.0.0/14"
    "169.252.0.0/15"
    "169.255.0.0/16"
    "170.0.0.0/7"
    "172.0.0.0/12"
    "172.32.0.0/11"
    "172.64.0.0/10"
    "172.128.0.0/9"
    "173.0.0.0/8"
    "174.0.0.0/7"
    "176.0.0.0/4"
    "192.0.1.0/24"
    "192.0.2.0/23"
    "192.0.4.0/22"
    "192.0.8.0/21"
    "192.0.16.0/20"
    "192.0.32.0/19"
    "192.0.64.0/18"
    "192.0.128.0/17"
    "192.1.0.0/16"
    "192.2.0.0/15"
    "192.4.0.0/14"
    "192.8.0.0/13"
    "192.16.0.0/12"
    "192.32.0.0/11"
    "192.64.0.0/10"
    "192.128.0.0/11"
    "192.160.0.0/13"
    "192.169.0.0/16"
    "192.170.0.0/15"
    "192.172.0.0/14"
    "192.176.0.0/12"
    "192.192.0.0/10"
    "193.0.0.0/8"
    "194.0.0.0/7"
    "196.0.0.0/7"
    "198.0.0.0/12"
    "198.16.0.0/15"
    "198.20.0.0/14"
    "198.24.0.0/13"
    "198.32.0.0/11"
    "198.64.0.0/10"
    "198.128.0.0/9"
    "199.0.0.0/8"
    "200.0.0.0/5"
    "208.0.0.0/4"
  ];

  # Tools every job gets. Repository-specific toolchains go in the runner's
  # own extraPackages.
  basePackages = with pkgs; [
    bash
    coreutils
    findutils
    gnused
    gnugrep
    gawk
    diffutils
    gnutar
    gzip
    xz
    zstd # actions/cache
    unzip
    which
    procps
    git
    jq
    yq-go
    gnumake
    curl
    wget
    openssl # the CLI; GitHub-hosted Ubuntu has it and test suites shell out to it
  ];

  # Settings for the nix client inside jobs. A file (not NIX_CONFIG) so a
  # workflow can still set NIX_CONFIG without dropping these. max-jobs and
  # cores are forwarded to the daemon even for untrusted users, which keeps
  # CI builds (they run in nix-daemon's cgroup, outside the runner's limits)
  # small.
  #
  # experimental-features is repeated from the host because jobs never see
  # /etc/nix/nix.conf: it ends in `!include /run/secrets/nix/access-tokens`,
  # /run/secrets.d is in InaccessiblePaths, and Nix drops the whole system
  # file when that include fails with EACCES (it only skips a missing one).
  # Keeping the access tokens out of jobs is intended; losing the rest of
  # the system file only matters for client-side settings like this one.
  nixClientConf = pkgs.writeText "github-runner-nix.conf"
    (lib.concatStrings (lib.mapAttrsToList (k: v: "${k} = ${v}\n") cfg.nixClientSettings));

  # Interpreter path that unpatched glibc binaries ask for, e.g.
  # /lib64/ld-linux-x86-64.so.2 on x86_64-linux.
  ldsoPath = "/${pkgs.stdenv.hostPlatform.libDir}/${builtins.baseNameOf pkgs.stdenv.cc.bintools.dynamicLinker}";

  # Same shape as programs.nix-ld's library env, but per runner.
  mkNixLdLibraries = name: libraries: pkgs.buildEnv {
    name = "github-runner-${name}-nix-ld-libraries";
    pathsToLink = [ "/lib" ];
    paths = map lib.getLib libraries;
    postBuild = ''
      ln -s ${pkgs.stdenv.cc.bintools.dynamicLinker} $out/share/nix-ld/lib/ld.so
    '';
    extraPrefix = "/share/nix-ld";
    ignoreCollisions = true;
  };

  # programs.nix-ld's default library set.
  defaultNixLdLibraries = with pkgs; [
    zlib
    zstd
    stdenv.cc.cc
    curl
    openssl
    attr
    libssh
    bzip2
    libxml2
    acl
    libsodium
    util-linux
    xz
    systemd
  ];

  runnerUser = name: "github-runner-${name}";
  runnerWorkDir = name: "${cfg.workRoot}/${name}";

  runnerSubmodule = lib.types.submodule ({ name, ... }: {
    options = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to run this repository's runner.";
      };

      url = lib.mkOption {
        type = lib.types.str;
        description = "Repository URL the runner registers with.";
        example = "https://github.com/carpenike/mcp";
      };

      labels = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ name ];
        defaultText = lib.literalExpression "[ <runner name> ]";
        description = ''
          Labels added on top of `baseLabels` and the system double
          (e.g. x86_64-linux). The runner's own name is the default, so a
          workflow can say `runs-on: [self-hosted, nixos, <name>]`.
        '';
      };

      extraPackages = lib.mkOption {
        type = lib.types.listOf lib.types.package;
        default = [ ];
        description = "Packages on PATH for this runner's jobs, on top of the base set.";
      };

      extraEnvironment = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        description = "Extra environment variables for this runner's jobs.";
      };

      ephemeral = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Run in ephemeral mode: the runner de-registers after one job, and
          the state and work directories are wiped before the next.
        '';
      };

      memoryHigh = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = "1536M";
        description = "systemd MemoryHigh= (throttle point) for the runner and its jobs.";
      };

      memoryMax = lib.mkOption {
        type = lib.types.str;
        default = "2G";
        description = "systemd MemoryMax= (OOM-kill point) for the runner and its jobs.";
      };

      cpuQuota = lib.mkOption {
        type = lib.types.str;
        default = "200%";
        description = "systemd CPUQuota= for the runner and its jobs (100% = one core).";
      };

      restrictNetwork = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Refuse traffic to private, CGNAT, link-local and all non-loopback
          IPv6 addresses (public IPv4 and loopback stay reachable). See the
          module header for what this does and does not cover.
        '';
      };

      nixLd = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = ''
            Bind nix-ld over the glibc loader path inside this runner's mount
            namespace, so downloaded glibc binaries (Node from setup-node, uv
            and python-build-standalone, ruff wheels, Playwright browsers) run.
            The host keeps its stub loader.
          '';
        };

        extraLibraries = lib.mkOption {
          type = lib.types.listOf lib.types.package;
          default = [ ];
          description = "Libraries added to programs.nix-ld's default set for this runner.";
        };
      };

      serviceOverrides = lib.mkOption {
        type = lib.types.attrs;
        default = { };
        description = "Escape hatch: extra systemd serviceConfig for this runner.";
      };
    };
  });
in
{
  options.modules.services.github-runner = {
    enable = lib.mkEnableOption "GitHub Actions self-hosted runners";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.github-runner;
      defaultText = lib.literalExpression "pkgs.github-runner";
      description = "Runner package for every runner.";
    };

    nodeRuntimes = lib.mkOption {
      type = lib.types.nullOr (lib.types.listOf (lib.types.enum [ "node20" "node24" ]));
      default = null;
      description = "Node runtimes passed to services.github-runners (null keeps the upstream default).";
    };

    tokenFile = lib.mkOption {
      type = lib.types.path;
      description = ''
        File holding the GitHub token every runner registers with: a
        fine-grained PAT whose repository access covers every runner URL,
        with "Administration: read and write" (needed to create repo-level
        runner registration tokens). Read only by the root-privileged
        ExecStartPre; hidden from the job user.
      '';
      example = "/run/secrets/github/runner-token";
    };

    namePrefix = lib.mkOption {
      type = lib.types.str;
      default = config.networking.hostName;
      defaultText = lib.literalExpression "config.networking.hostName";
      description = "Runner names registered with GitHub are `<namePrefix>-<runner>`.";
    };

    baseLabels = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "nixos" config.networking.hostName ];
      defaultText = lib.literalExpression ''[ "nixos" config.networking.hostName ]'';
      description = "Labels every runner carries (GitHub also adds self-hosted, Linux, X64).";
    };

    workRoot = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/github-runner-work";
      description = ''
        Parent of each runner's on-disk work directory (also the job's HOME).
        Upstream defaults to a RuntimeDirectory on /run, which is tmpfs and is
        charged to the runner's memory cgroup; checkouts, node_modules and
        toolchain downloads belong on disk.
      '';
    };

    allowedAddresses = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Extra addresses (CIDR) runners with restrictNetwork may reach, e.g.
        the host's DNS resolver when it sits on the LAN.
      '';
    };

    slice = {
      memoryMax = lib.mkOption {
        type = lib.types.str;
        default = "4G";
        description = "Ceiling for all runners together (github-runners.slice MemoryMax=).";
      };

      cpuQuota = lib.mkOption {
        type = lib.types.str;
        default = "400%";
        description = "Ceiling for all runners together (github-runners.slice CPUQuota=).";
      };
    };

    nixBuild = {
      maxJobs = lib.mkOption {
        type = lib.types.ints.positive;
        default = 1;
        description = "max-jobs requested from nix-daemon by CI jobs.";
      };

      cores = lib.mkOption {
        type = lib.types.ints.positive;
        default = 2;
        description = "cores requested from nix-daemon by CI jobs.";
      };
    };

    nixClientSettings = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      internal = true;
      readOnly = true;
      default = {
        experimental-features = lib.concatStringsSep " " config.nix.settings.experimental-features;
        accept-flake-config = "true";
        max-jobs = toString cfg.nixBuild.maxJobs;
        cores = toString cfg.nixBuild.cores;
      };
      description = "Rendered into every job's NIX_USER_CONF_FILES. Exposed for the contract check.";
    };

    runners = lib.mkOption {
      type = lib.types.attrsOf runnerSubmodule;
      default = { };
      description = "Repository runners, keyed by a short name (used for the unit, user and label).";
    };

    # Standard monitoring integration
    notifications = lib.mkOption {
      type = lib.types.nullOr sharedTypes.notificationSubmodule;
      default = null;
      description = "Notification configuration for service failures";
    };
  };

  config = lib.mkIf cfg.enable {
    services.github-runners = lib.mapAttrs
      (name: r:
        let
          nixLdLibraries = mkNixLdLibraries name (defaultNixLdLibraries ++ r.nixLd.extraLibraries);
        in
        {
          enable = true;
          inherit (r) url ephemeral;
          inherit (cfg) tokenFile package;
          name = "${cfg.namePrefix}-${name}";
          replace = true;

          # Static per-runner identity (DynamicUser is off because a static
          # owner lets tmpfiles create the on-disk work directory).
          user = runnerUser name;
          group = runnerUser name;
          workDir = runnerWorkDir name;

          extraLabels = cfg.baseLabels
          ++ [ pkgs.stdenv.hostPlatform.system ]
          ++ r.labels;

          extraPackages = basePackages ++ r.extraPackages;

          extraEnvironment = {
            NIX_USER_CONF_FILES = "${nixClientConf}";
            # Prebuilt toolchains (setup-python, uv's standalone CPython) look
            # for CAs at Debian/RHEL paths that NixOS does not have, so TLS
            # verification fails. NixOS's bundle, which follows CA updates.
            SSL_CERT_FILE = "/etc/ssl/certs/ca-certificates.crt";
          }
          // lib.optionalAttrs r.nixLd.enable {
            NIX_LD = "${nixLdLibraries}/share/nix-ld/lib/ld.so";
            NIX_LD_LIBRARY_PATH = "${nixLdLibraries}/share/nix-ld/lib";
          }
          // r.extraEnvironment;

          serviceOverrides = lib.mkMerge [
            {
              Slice = "github-runners.slice";

              # Resource fencing (see slice for the shared ceiling)
              MemoryAccounting = true;
              MemoryMax = r.memoryMax;
              MemorySwapMax = "0";
              CPUQuota = r.cpuQuota;
              CPUWeight = 20;
              IOWeight = 20;
              Nice = 10;
              CPUSchedulingPolicy = "batch";
              IOSchedulingClass = "best-effort";
              IOSchedulingPriority = 7;

              # Nix client: talk to the daemon socket. Everything else under
              # / stays read-only (upstream ProtectSystem=strict).
              ReadWritePaths = [ "/nix/var/nix/daemon-socket" ];

              # Defense in depth on top of upstream's ProtectHome=true,
              # PrivateTmp, PrivateDevices, PrivateUsers, NoNewPrivileges and
              # empty capability set: hide host secrets and world-connectable
              # local sockets that a job has no business reaching.
              InaccessiblePaths = [
                "-/run/secrets.d"
                "-/run/secrets-for-users.d"
                "-/run/keys"
                "-/run/postgresql"
                "-/run/podman"
                "-/run/docker.sock"
                "-/run/ssh-unix-local"
                "-/run/avahi-daemon"
                "-/run/rpcbind.sock"
                "-/var/lib/caddy"
                "-/var/lib/containers"
                "-/var/lib/postgresql"
                "-/var/lib/backup-docs"
                "-/var/lib/backup-snapshots"
                "-/var/lib/prometheus2"
                "-/var/lib/unifi"
                "-/var/lib/libvirt"
                "-/var/lib/atrium-policy"
                "-/persist/var"
              ];
            }
            (lib.mkIf (r.memoryHigh != null) {
              MemoryHigh = r.memoryHigh;
            })
            (lib.mkIf r.restrictNetwork {
              IPAddressDeny = "any";
              IPAddressAllow = [ "127.0.0.0/8" "::1/128" ]
              ++ publicIPv4
              ++ cfg.allowedAddresses;
            })
            (lib.mkIf r.nixLd.enable {
              # Only inside this unit's mount namespace; the host keeps the
              # stub loader. Follows the symlink to the stub-ld store file.
              BindReadOnlyPaths = [ "${pkgs.nix-ld}/libexec/nix-ld:${ldsoPath}" ];
            })
            r.serviceOverrides
          ];
        }
        // lib.optionalAttrs (cfg.nodeRuntimes != null) {
          inherit (cfg) nodeRuntimes;
        })
      enabledRunners;

    users.users = lib.mapAttrs'
      (name: _: lib.nameValuePair (runnerUser name) {
        isSystemUser = true;
        group = runnerUser name;
        description = "GitHub Actions runner for ${name}";
        home = runnerWorkDir name;
        createHome = false;
      })
      enabledRunners;

    users.groups = lib.mapAttrs'
      (name: _: lib.nameValuePair (runnerUser name) { })
      enabledRunners;

    # On-disk work directories, owner-only. The runner's ExecStartPre empties
    # them before every job.
    systemd.tmpfiles.rules =
      [ "d ${cfg.workRoot} 0755 root root -" ]
      ++ lib.mapAttrsToList
        (name: _: "d ${runnerWorkDir name} 0700 ${runnerUser name} ${runnerUser name} -")
        enabledRunners;

    systemd.slices.github-runners = {
      description = "GitHub Actions self-hosted runners";
      sliceConfig = {
        MemoryAccounting = true;
        MemoryMax = cfg.slice.memoryMax;
        MemorySwapMax = "0";
        CPUQuota = cfg.slice.cpuQuota;
        CPUWeight = 20;
        IOWeight = 20;
      };
    };

    # Firewall: runners don't need inbound access (they poll GitHub)

    assertions = [
      {
        assertion = enabledRunners != { };
        message = "modules.services.github-runner is enabled but no runner is enabled";
      }
    ] ++ lib.mapAttrsToList
      (name: r: {
        assertion = lib.hasPrefix "https://github.com/" r.url
          && lib.length (lib.filter (s: s != "") (lib.splitString "/" (lib.removePrefix "https://github.com/" r.url))) == 2;
        message = "modules.services.github-runner.runners.${name}.url must be a repository URL (https://github.com/<owner>/<repo>)";
      })
      enabledRunners;
  };
}
