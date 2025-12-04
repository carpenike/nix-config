_:
{
  modules.shell.bash = {
    enable = true;
    launchFishForInteractive = true;
  };

  # Trust all git directories when using VS Code Remote-SSH
  # This is needed because VS Code runs as the ryan user but may access
  # repositories in locations with different ownership
  modules.shell.git.trustedDirectories = [ "*" ];
}
