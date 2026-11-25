{ pkgs
, config
, lib
, ...
}:
# disk-watch: hourly free-space + hotspot-growth monitor for rymac.
#
# Alerts as a macOS toast (terminal-notifier) for every alert, and also via
# Pushover for the critical level. It only measures and alerts; it never
# deletes anything.
let
  home = config.home.homeDirectory;
  sopsFile = ../../secrets.sops.yaml;

  # Pushover is optional: declare the sops secrets only once the encrypted
  # file actually holds them. Declaring a missing key would make sops-nix fail
  # activation for every secret in the file (including www-shield's).
  # Add them with:  sops home/ryan/secrets.sops.yaml
  #   pushover:
  #     token: <app token>
  #     user-key: <user key>
  pushoverConfigured = lib.hasInfix "\npushover:" (builtins.readFile sopsFile);

  # label|path. Paths may be globs; @usertmp@ is the per-user /var/folders dir.
  # Avoid TCC-protected locations (~/Downloads, ~/Documents, ~/Desktop,
  # ~/Library/Containers, ~/Library/Group Containers): a background du there
  # would raise a macOS privacy prompt.
  hotspots = [
    "Parallels VMs|${home}/Parallels"
    "LM Studio models|${home}/.cache/lm-studio"
    "Swap files|/System/Volumes/VM"
    "Chrome code-sign clones|@usertmp@/X"
    "User temp|@usertmp@/T"
    "Claude Code worktrees|${home}/src/*/.claude/worktrees"
    "Podman storage|${home}/.local/share/containers"
    "uv cache|${home}/.cache/uv"
    "npm cache|${home}/.npm"
    "VS Code workspace storage|${home}/Library/Application Support/Code/User/workspaceStorage"
    "Claude desktop|${home}/Library/Application Support/Claude"
    "Steam|${home}/Library/Application Support/Steam"
    "User caches|${home}/Library/Caches"
    "Nix store|/nix/store"
  ];

  # Baked into the script as defaults, so the launchd agent and an interactive
  # `disk-watch status` see the same settings (the environment can override).
  settings = {
    DW_VOLUME = "/System/Volumes/Data";
    DW_WARN_GB = "50";
    DW_CRIT_GB = "20";
    DW_DROP_GB = "15";
    DW_GROWTH_GB = "10";
    DW_STATE_DIR = "${home}/Library/Application Support/disk-watch";
    DW_HOTSPOTS = lib.concatStringsSep "\n" hotspots;
  } // lib.optionalAttrs pushoverConfigured {
    DW_PUSHOVER_TOKEN_FILE = config.sops.secrets."pushover/token".path;
    DW_PUSHOVER_USER_FILE = config.sops.secrets."pushover/user-key".path;
  };

  diskWatch = pkgs.writeShellApplication {
    name = "disk-watch";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.curl
      pkgs.gawk
      pkgs.gnugrep
      pkgs.terminal-notifier
    ];
    text =
      lib.concatStrings (lib.mapAttrsToList (n: v: "${n}=\${${n}:-${lib.escapeShellArg v}}\nexport ${n}\n") settings)
      + builtins.readFile ./disk-watch.sh;
  };
in
{
  home.packages = [ diskWatch ];

  sops.secrets = lib.mkIf pushoverConfigured {
    "pushover/token" = { };
    "pushover/user-key" = { };
  };

  launchd.agents.disk-watch = {
    enable = true;
    config = {
      ProgramArguments = [ "${diskWatch}/bin/disk-watch" "run" ];
      RunAtLoad = true;
      StartInterval = 3600;
      ProcessType = "Background";
      LowPriorityIO = true;
      Nice = 10;
      StandardOutPath = "${home}/Library/Logs/disk-watch.log";
      StandardErrorPath = "${home}/Library/Logs/disk-watch.log";
    };
  };
}
