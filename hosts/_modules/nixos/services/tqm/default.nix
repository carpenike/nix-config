{ config, lib, pkgs, ... }:

let
  cfg = config.modules.services.tqm;

  # Build the YAML configuration for tqm
  yamlFormat = pkgs.formats.yaml {};

  # Build client configuration
  clientConfig = {
    qbt = {
      enabled = true;
      type = "qbittorrent";
      url = "http://${cfg.client.host}:${toString cfg.client.port}/";
      download_path = cfg.client.downloadPath;
      filter = "default";
    } // lib.optionalAttrs (cfg.client.downloadPathMapping != {}) {
      download_path_mapping = cfg.client.downloadPathMapping;
    } // lib.optionalAttrs (cfg.client.user != null) {
      user = cfg.client.user;
    } // lib.optionalAttrs (cfg.client.password != null) {
      password = cfg.client.password;
    } // lib.optionalAttrs cfg.client.enableAutoTmmAfterRelabel {
      enableAutoTmmAfterRelabel = true;
    } // lib.optionalAttrs cfg.client.createTagsUpfront {
      create_tags_upfront = true;
    };
  };

  configFile = yamlFormat.generate "tqm-config.yml" (lib.recursiveUpdate {
    clients = clientConfig;

    bypassIgnoreIfUnregistered = cfg.bypassIgnoreIfUnregistered;

    filters = cfg.filters;

  } (lib.optionalAttrs (cfg.notifications != null) {
    notifications = {
      detailed = cfg.notifications.detailed;
      skip_empty_run = cfg.notifications.skipEmptyRun;
    } // lib.optionalAttrs (cfg.notifications.discord != null) {
      service.discord = {
        webhook_url = cfg.notifications.discord.webhookUrl;
      } // lib.optionalAttrs (cfg.notifications.discord.username != null) {
        username = cfg.notifications.discord.username;
      } // lib.optionalAttrs (cfg.notifications.discord.avatarUrl != null) {
        avatar_url = cfg.notifications.discord.avatarUrl;
      };
    };
  }) // lib.optionalAttrs (cfg.trackers != {}) {
    trackers = cfg.trackers;
  } // cfg.extraConfig);

in {
  options.modules.services.tqm = {
    enable = lib.mkEnableOption "tqm - Torrent Queue Manager";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ./package.nix {};
      description = "The tqm package to use";
    };

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/tqm";
      description = "Directory for tqm state and logs";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "tqm";
      description = "User account under which tqm runs";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "tqm";
      description = "Group under which tqm runs";
    };

    # Client configuration
    client = {
      type = lib.mkOption {
        type = lib.types.enum [ "qbittorrent" "deluge" ];
        default = "qbittorrent";
        description = "Torrent client type";
      };

      host = lib.mkOption {
        type = lib.types.str;
        default = "localhost";
        description = "Torrent client host";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 8080;
        description = "Torrent client port";
      };

      user = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Torrent client username (null if auth disabled)";
      };

      password = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Torrent client password (null if auth disabled)";
      };

      downloadPath = lib.mkOption {
        type = lib.types.str;
        default = "/mnt/data/qb/downloads";
        description = "Download path on the server";
      };

      downloadPathMapping = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = {};
        description = "Path mapping for container environments";
      };

      enableAutoTmmAfterRelabel = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable Auto Torrent Management Mode after relabeling";
      };

      createTagsUpfront = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Create all tags upfront vs only when matched";
      };
    };

    # Notifications
    notifications = lib.mkOption {
      type = lib.types.nullOr (lib.types.submodule {
        options = {
          detailed = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Send detailed information about each action";
          };

          skipEmptyRun = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Skip notification if no actions taken";
          };

          discord = lib.mkOption {
            type = lib.types.nullOr (lib.types.submodule {
              options = {
                webhookUrl = lib.mkOption {
                  type = lib.types.str;
                  description = "Discord webhook URL";
                };

                username = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                  description = "Override webhook username";
                };

                avatarUrl = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                  description = "Override webhook avatar URL";
                };
              };
            });
            default = null;
            description = "Discord notification configuration";
          };
        };
      });
      default = null;
      description = "Notification settings";
    };

    # Tracker API integration
    trackers = lib.mkOption {
      type = lib.types.attrsOf lib.types.attrs;
      default = {};
      description = "Tracker API configurations for validation";
    };

    bypassIgnoreIfUnregistered = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Unregistered torrents bypass ignore filters";
    };

    # Filter configuration - this is the core of tqm
    filters = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          MapHardlinksFor = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [];
            description = "Commands that should map hardlinks";
          };

          DeleteData = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Delete torrent data from disk when removing";
          };

          ignore = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [];
            description = "Filter expressions for torrents to ignore";
          };

          remove = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [];
            description = "Filter expressions for torrents to remove";
          };

          pause = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [];
            description = "Filter expressions for torrents to pause";
          };

          label = lib.mkOption {
            type = lib.types.listOf (lib.types.submodule {
              options = {
                name = lib.mkOption {
                  type = lib.types.str;
                  description = "Label name to set";
                };

                update = lib.mkOption {
                  type = lib.types.listOf lib.types.str;
                  description = "Filter expressions (all must match)";
                };
              };
            });
            default = [];
            description = "Label rules for relabeling torrents";
          };

          tag = lib.mkOption {
            type = lib.types.listOf (lib.types.submodule {
              options = {
                name = lib.mkOption {
                  type = lib.types.str;
                  description = "Tag name";
                };

                mode = lib.mkOption {
                  type = lib.types.enum [ "full" "add" "remove" ];
                  default = "full";
                  description = "Tag mode";
                };

                uploadKb = lib.mkOption {
                  type = lib.types.nullOr lib.types.int;
                  default = null;
                  description = "Upload speed limit in KiB/s";
                };

                update = lib.mkOption {
                  type = lib.types.listOf lib.types.str;
                  description = "Filter expressions for tagging";
                };
              };
            });
            default = [];
            description = "Tag rules for retagging torrents";
          };

          orphan = lib.mkOption {
            type = lib.types.nullOr (lib.types.submodule {
              options = {
                grace_period = lib.mkOption {
                  type = lib.types.str;
                  default = "10m";
                  description = "Grace period for recently modified files";
                };

                ignore_paths = lib.mkOption {
                  type = lib.types.listOf lib.types.str;
                  default = [];
                  description = "Paths to ignore during orphan check";
                };
              };
            });
            default = null;
            description = "Orphan file detection configuration";
          };
        };
      });
      default = {};
      description = "Filter configurations per named filter set";
    };

    # Schedule for each command
    schedules = {
      clean = lib.mkOption {
        type = lib.types.str;
        default = "*:0/15";
        description = "Systemd calendar spec for tqm clean";
      };

      relabel = lib.mkOption {
        type = lib.types.str;
        default = "*:0/30";
        description = "Systemd calendar spec for tqm relabel";
      };

      retag = lib.mkOption {
        type = lib.types.str;
        default = "*:0/30";
        description = "Systemd calendar spec for tqm retag";
      };

      orphan = lib.mkOption {
        type = lib.types.str;
        default = "daily";
        description = "Systemd calendar spec for tqm orphan";
      };

      pause = lib.mkOption {
        type = lib.types.str;
        default = "*:0/30";
        description = "Systemd calendar spec for tqm pause";
      };
    };

    extraConfig = lib.mkOption {
      type = lib.types.attrs;
      default = {};
      description = "Additional tqm configuration";
    };
  };

  config = lib.mkIf cfg.enable {
    # Create user and group
    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
      home = cfg.dataDir;
      description = "tqm service user";
    };

    users.groups.${cfg.group} = {};

    # Create systemd services for each tqm command
    systemd.services = {
      tqm-clean = {
        description = "tqm clean - Remove torrents based on filters";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];

        serviceConfig = {
          Type = "oneshot";
          User = cfg.user;
          Group = cfg.group;
          ExecStart = "${cfg.package}/bin/tqm clean qbt --config ${configFile}";
          WorkingDirectory = cfg.dataDir;
          StateDirectory = "tqm";
        };
      };

      tqm-relabel = {
        description = "tqm relabel - Relabel torrents based on filters";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];

        serviceConfig = {
          Type = "oneshot";
          User = cfg.user;
          Group = cfg.group;
          ExecStart = "${cfg.package}/bin/tqm relabel qbt --config ${configFile}";
          WorkingDirectory = cfg.dataDir;
          StateDirectory = "tqm";
        };
      };

      tqm-retag = {
        description = "tqm retag - Retag torrents based on filters";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];

        serviceConfig = {
          Type = "oneshot";
          User = cfg.user;
          Group = cfg.group;
          ExecStart = "${cfg.package}/bin/tqm retag qbt --config ${configFile}";
          WorkingDirectory = cfg.dataDir;
          StateDirectory = "tqm";
        };
      };

      tqm-orphan = {
        description = "tqm orphan - Find and remove orphaned files";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];

        serviceConfig = {
          Type = "oneshot";
          User = cfg.user;
          Group = cfg.group;
          ExecStart = "${cfg.package}/bin/tqm orphan qbt --config ${configFile}";
          WorkingDirectory = cfg.dataDir;
          StateDirectory = "tqm";
        };
      };

      tqm-pause = {
        description = "tqm pause - Pause torrents based on filters";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];

        serviceConfig = {
          Type = "oneshot";
          User = cfg.user;
          Group = cfg.group;
          ExecStart = "${cfg.package}/bin/tqm pause qbt --config ${configFile}";
          WorkingDirectory = cfg.dataDir;
          StateDirectory = "tqm";
        };
      };
    };

    # Create systemd timers for each command
    systemd.timers = {
      tqm-clean = {
        description = "Timer for tqm clean";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = cfg.schedules.clean;
          Persistent = true;
          Unit = "tqm-clean.service";
        };
      };

      tqm-relabel = {
        description = "Timer for tqm relabel";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = cfg.schedules.relabel;
          Persistent = true;
          Unit = "tqm-relabel.service";
        };
      };

      tqm-retag = {
        description = "Timer for tqm retag";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = cfg.schedules.retag;
          Persistent = true;
          Unit = "tqm-retag.service";
        };
      };

      tqm-orphan = {
        description = "Timer for tqm orphan";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = cfg.schedules.orphan;
          Persistent = true;
          Unit = "tqm-orphan.service";
        };
      };

      tqm-pause = {
        description = "Timer for tqm pause";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = cfg.schedules.pause;
          Persistent = true;
          Unit = "tqm-pause.service";
        };
      };
    };
  };
}
