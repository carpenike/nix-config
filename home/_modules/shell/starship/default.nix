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

      settings = {
        # Performance
        command_timeout = 500;

        # Beautiful two-line powerline prompt
        # Using literal powerline glyphs from Nerd Fonts
        format = lib.concatStrings [
          "$os"
          "$username"
          "[ ](bg:lavender fg:blue)"
          "$directory"
          "[ ](bg:mauve fg:lavender)"
          "$git_branch"
          "$git_status"
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

        # OS icon segment - using official Starship Nerd Font preset icons
        os = {
          disabled = false;
          style = "bg:blue fg:base";
          symbols = {
            Macos = "";
            Ubuntu = "";
            Debian = "";
            NixOS = "";
            Windows = "󰍲";
            Linux = "";
          };
          format = "[  $symbol  ]($style)";
        };

        # Username
        username = {
          disabled = false;
          show_always = true;
          style_user = "bg:blue fg:base bold";
          style_root = "bg:red fg:base bold";
          format = "[ $user  ]($style)";
        };

        # Directory with folder icon - lavender bg
        directory = {
          truncation_length = 3;
          truncation_symbol = "…/";
          style = "bg:lavender fg:base bold";
          read_only = " 󰌾";
          read_only_style = "bg:lavender fg:red";
          format = "[  $path  ]($style)[$read_only]($read_only_style)";
        };

        # Git branch - mauve bg
        git_branch = {
          symbol = "󰘬";
          style = "bg:mauve fg:base";
          format = "[  $symbol $branch(:$remote_branch)  ]($style)";
        };

        # Git status - clear icons
        git_status = {
          style = "bg:mauve fg:base";
          format = "[$all_status$ahead_behind ]($style)";
          conflicted = "󱧂 ";
          ahead = "󰜸$count ";
          behind = "󰜯$count ";
          diverged = "󰜸$ahead_count󰜯$behind_count ";
          untracked = "󰋗$count ";
          stashed = "󰆓$count ";
          modified = "󰏫$count ";
          staged = "󰸞$count ";
          renamed = "󰑕$count ";
          deleted = "󰆴$count ";
        };

        # Python - peach bg
        python = {
          symbol = "󰌠";
          style = "bg:peach fg:base";
          format = "[](bg:peach fg:mauve)[  $symbol $virtualenv  ]($style)[](fg:peach)";
          detect_extensions = ["py"];
          detect_files = ["pyproject.toml" "requirements.txt" "Pipfile"];
        };

        # Node.js - peach bg
        nodejs = {
          symbol = "󰎙";
          style = "bg:peach fg:base";
          format = "[](bg:peach fg:mauve)[  $symbol $version  ]($style)[](fg:peach)";
          detect_extensions = ["js" "ts" "jsx" "tsx"];
          detect_files = ["package.json"];
        };

        # Go - peach bg
        golang = {
          symbol = "󰟓";
          style = "bg:peach fg:base";
          format = "[](bg:peach fg:mauve)[  $symbol $version  ]($style)[](fg:peach)";
        };

        # Rust - peach bg
        rust = {
          symbol = "󱘗";
          style = "bg:peach fg:base";
          format = "[](bg:peach fg:mauve)[  $symbol $version  ]($style)[](fg:peach)";
        };

        # Nix shell - peach bg
        nix_shell = {
          symbol = "";
          style = "bg:peach fg:base";
          impure_msg = "";
          pure_msg = "pure";
          format = "[](bg:peach fg:mauve)[  $symbol $state  ]($style)[](fg:peach)";
        };

        # Command duration - yellow bg
        cmd_duration = {
          min_time = 500;
          style = "bg:yellow fg:base";
          format = "[](bg:yellow fg:mauve)[  󱎫 $duration  ]($style)[](fg:yellow)";
        };

        # Time - right side
        time = {
          disabled = false;
          time_format = "%H:%M";
          style = "bg:surface1 fg:text";
          format = "[  󰥔 $time  ]($style)";
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
