{ pkgs
, lib
, ...
}:
{
  config = {
    programs.starship = {
      enable = true;
      package = pkgs.unstable.starship;
      catppuccin.enable = true;

      # Disable starship for bash - VS Code terminals use bash and starship's
      # complex escape sequences interfere with VS Code Copilot's terminal parsing
      enableBashIntegration = false;

      settings = {
        # Performance
        command_timeout = 500;

        # Powerline prompt with rounded separators
        # Core segments use powerline transitions
        # Optional segments (languages, duration) are floating blocks
        format = lib.concatStrings [
          "$os"
          "$username"
          "[](bg:lavender fg:blue)"
          "$directory"
          "[](bg:mauve fg:lavender)"
          "$git_branch"
          "$git_status"
          "[](fg:mauve)"
          "$python"
          "$nodejs"
          "$golang"
          "$rust"
          "$nix_shell"
          "$cmd_duration"
          "$fill"
          "[](fg:surface1)"
          "$time"
          "\n"
          "$character"
        ];

        # Fill space between left and right
        fill.symbol = " ";

        # OS icon segment
        os = {
          disabled = false;
          style = "bg:blue fg:base";
          symbols = {
            Macos = "";
            Ubuntu = "";
            Debian = "";
            NixOS = "";
            Windows = "󰷒";
            Linux = "";
          };
          format = "[](fg:blue)[  $symbol  ]($style)";
        };

        # Username
        username = {
          disabled = false;
          show_always = true;
          style_user = "bg:blue fg:base bold";
          style_root = "bg:red fg:base bold";
          format = "[ $user  ]($style)";
        };

        # Directory
        directory = {
          truncation_length = 3;
          truncation_symbol = "…/";
          style = "bg:lavender fg:base bold";
          read_only = " 󰌾";
          read_only_style = "bg:lavender fg:red";
          format = "[  $path  ]($style)[$read_only]($read_only_style)";
        };

        # Git branch
        git_branch = {
          symbol = "󰘬";
          style = "bg:mauve fg:base";
          format = "[  $symbol $branch(:$remote_branch)  ]($style)";
        };

        # Git status
        git_status = {
          style = "bg:mauve fg:base";
          format = "[$all_status$ahead_behind ]($style)";
          conflicted = "󱹂 ";
          ahead = "󰜷$count ";
          behind = "󰜯$count ";
          diverged = "󰜷$ahead_count󰜯$behind_count ";
          untracked = "󰋗$count ";
          stashed = "󰆓$count ";
          modified = "󰏫$count ";
          staged = "󰸞$count ";
          renamed = "󰑕$count ";
          deleted = "󰆴$count ";
        };

        # Python - floating peach block
        python = {
          symbol = "󰌠";
          style = "bg:peach fg:base";
          format = " [](fg:peach)[  $symbol $virtualenv  ]($style)[](fg:peach)";
          detect_extensions = [ "py" ];
          detect_files = [ "pyproject.toml" "requirements.txt" "Pipfile" ];
        };

        # Node.js - floating peach block
        nodejs = {
          symbol = "󰎙";
          style = "bg:peach fg:base";
          format = " [](fg:peach)[  $symbol $version  ]($style)[](fg:peach)";
          detect_extensions = [ "js" "ts" "jsx" "tsx" ];
          detect_files = [ "package.json" ];
        };

        # Go - floating peach block
        golang = {
          symbol = "󰟓";
          style = "bg:peach fg:base";
          format = " [](fg:peach)[  $symbol $version  ]($style)[](fg:peach)";
        };

        # Rust - floating peach block
        rust = {
          symbol = "󱘗";
          style = "bg:peach fg:base";
          format = " [](fg:peach)[  $symbol $version  ]($style)[](fg:peach)";
        };

        # Nix shell - floating peach block
        nix_shell = {
          disabled = true;
          symbol = "";
          style = "bg:peach fg:base";
          impure_msg = "";
          pure_msg = "pure";
          format = " [](fg:peach)[  $symbol $state  ]($style)[](fg:peach)";
        };

        # Command duration - floating yellow block
        cmd_duration = {
          min_time = 500;
          style = "bg:yellow fg:base";
          format = " [](fg:yellow)[  󱎫 $duration  ]($style)[](fg:yellow)";
        };

        # Time - right side
        time = {
          disabled = false;
          time_format = "%H:%M";
          style = "bg:surface1 fg:text";
          format = "[  󰥔 $time  ]($style)[](fg:surface1)";
        };

        # Prompt character
        character = {
          success_symbol = "[❯](bold green)";
          error_symbol = "[❯](bold red)";
          vimcmd_symbol = "[❮](bold mauve)";
        };

        # Disabled modules
        kubernetes.disabled = true;
        aws.disabled = true;
        gcloud.disabled = true;
        azure.disabled = true;
      };
    };
  };
}
