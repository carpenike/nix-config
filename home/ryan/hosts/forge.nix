{ pkgs
, ...
}:
{
  modules.development.enable = true;

  # Claude Code: install via nixpkgs rather than the upstream curl installer,
  # which ships a generic dynamically-linked binary that cannot run on NixOS.
  # Sourced from unstable to track Claude Code's rapid release cadence.
  home.packages = [ pkgs.unstable.claude-code ];

  modules.shell.bash = {
    enable = true;
    launchFishForInteractive = true;
  };

  # Trust all git directories when using VS Code Remote-SSH
  # This is needed because VS Code runs as the ryan user but may access
  # repositories in locations with different ownership
  modules.shell.git.trustedDirectories = [ "*" ];

  # Enable GPG for commit signing via forwarded agent from Mac
  # The GPG agent socket is forwarded from the Mac via SSH RemoteForward
  # configured in the rymac home-manager config
  modules.security.gnugpg.enable = true;
}
