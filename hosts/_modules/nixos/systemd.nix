_: {
  # Disable automatic generation of /etc/machine-id to allow impermanence to manage it
  systemd.services."systemd-machine-id-setup" = {
    enable = false; # Prevent NixOS from overwriting /etc/machine-id
  };

  # Optional: Adjust other common systemd settings if needed
  systemd = {
    # Example: Increase default file descriptor limit for services
    defaultLimits = {
      NOFILE = 1048576;
    };

    # Example: Enable persistent journaling for system logs
    journald = {
      settings = {
        Storage = "persistent"; # Stores logs on disk
        Compress = "yes";       # Compresses older logs
        SystemMaxUse = "500M";  # Limits log storage usage
      };
    };
  };
}
