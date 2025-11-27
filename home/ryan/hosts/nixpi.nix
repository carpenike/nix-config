{ config
, lib
, pkgs
, ...
}:
{
  # Nixpi-specific home configuration

  # Enable development modules for Python work
  modules.development.enable = true;

  # Additional packages needed for nixpi
  home.packages = with pkgs; [
    # System monitoring (not in common utilities)
    htop
    iotop
    lsof
    strace

    # Network debugging tools
    iw
    wirelesstools
    ethtool
    tcpdump

    # Python packages for RVC development
    python3Packages.python-can
    python3Packages.pyyaml
    python3Packages.cantools
    python3Packages.pyperclip

    # Note: Hardware-specific packages remain in system configuration:
    # - can-utils (provided by pican2-duo hardware module)
    # - i2c-tools (provided by hardware modules)
    # - libraspberrypi (provided by raspberry-pi hardware module)
    # - raspberrypi-eeprom (provided by raspberry-pi hardware module)
  ];
}
