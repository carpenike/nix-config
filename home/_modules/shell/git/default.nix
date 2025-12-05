{ pkgs
, config
, lib
, ...
}:
let
  cfg = config.modules.shell.git;
  inherit (pkgs.stdenv) isDarwin;
in
{
  options.modules.shell.git = {
    enable = lib.mkEnableOption "git";
    username = lib.mkOption {
      type = lib.types.str;
    };
    email = lib.mkOption {
      type = lib.types.str;
    };
    signingKey = lib.mkOption {
      type = lib.types.str;
    };
    config = lib.mkOption {
      type = lib.types.attrs;
      default = { };
    };
    includes = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      default = [ ];
    };
    trustedDirectories = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "List of directories to add to git's safe.directory config";
      example = [ "/var/lib/myrepo" "*" ];
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      programs.gh.enable = true;
      programs.gpg.enable = true;

      programs.git = {
        enable = true;

        settings = lib.mkMerge [
          {
            user = {
              name = cfg.username;
              email = cfg.email;
            };
            core = {
              autocrlf = "input";
            };
            init = {
              defaultBranch = "main";
            };
            pull = {
              rebase = true;
            };
            rebase = {
              autoStash = true;
            };
            alias = {
              co = "checkout";
            };
          }
          # Add safe.directory entries if configured
          (lib.mkIf (cfg.trustedDirectories != [ ]) {
            safe = {
              directory = cfg.trustedDirectories;
            };
          })
          cfg.config
        ];

        includes = cfg.includes;

        ignores = [
          # Mac OS X hidden files
          ".DS_Store"
          # Windows files
          "Thumbs.db"
          # Sops
          ".decrypted~*"
          "*.decrypted.*"
          # Python virtualenvs
          ".venv"
        ];
        signing = {
          signByDefault = true;
          key = cfg.signingKey;
        };
      };

      home.packages = [
        pkgs.git-filter-repo
        pkgs.tig
      ];
    })
    (lib.mkIf (cfg.enable && isDarwin) {
      programs.git = {
        settings = {
          credential = { helper = "osxkeychain"; };
        };
      };
    })
  ];
}
