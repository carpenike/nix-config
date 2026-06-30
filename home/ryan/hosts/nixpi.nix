{ pkgs
, ...
}:
{
  # Nixpi-specific home configuration.
  #
  # Keep this an APPLIANCE profile, not the full workstation profile: the Pi has
  # a small (10GB) /nix store, so we deliberately do NOT pull the dev toolchain
  # or cloud CLIs onto it. Only the RVC Python libraries below are installed.

  # Dev utilities (nixd -> LLVM, prettier, helm-ls, cue, minio-client, ...): off.
  modules.development.enable = false;

  # The shared languages module defaults python/nodejs/go to ON; disable them
  # here so the appliance doesn't carry Go (-> gcc), Node.js, and the python311
  # dev stack. The RVC Python libs we actually need are in home.packages below
  # (they use the base python3, not the heavy dev toolchain).
  modules.development.languages = {
    python.enable = false;
    nodejs.enable = false;
    go.enable = false;
  };

  # Cloud / infra CLIs (azure-cli, terraform, talosctl, lima): not needed here.
  modules.infrastructure.enable = false;

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

    # Python interpreter + RVC libraries for ad-hoc CAN/RV-C work.
    # Use python3.withPackages so `python3` is actually on PATH with these libs
    # importable — bare python3Packages.* entries don't expose an interpreter.
    # (Kept deliberately minimal; the heavy python311 dev stack from the shared
    # languages module stays disabled on this appliance.)
    (python3.withPackages (ps: with ps; [
      python-can
      pyyaml
      cantools
      pyperclip
    ]))

    # Note: Hardware-specific packages remain in system configuration:
    # - can-utils (provided by pican2-duo hardware module)
    # - i2c-tools (provided by hardware modules)
    # - libraspberrypi (provided by raspberry-pi hardware module)
    # - raspberrypi-eeprom (provided by raspberry-pi hardware module)
  ];
}
