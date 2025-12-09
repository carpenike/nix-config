_: {
  # Disable automatic generation of /etc/machine-id to allow impermanence to manage it
  systemd.services."systemd-machine-id-setup" = {
    enable = false; # Prevent NixOS from overwriting /etc/machine-id
  };
}
