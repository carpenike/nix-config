{ ... }:
{
  # System packages are empty - update-nix script is provided by common module
  environment.systemPackages = [ ];

  # Note: Package organization follows repository patterns:
  # - User packages: Moved to home/ryan/hosts/nixpi.nix
  # - Hardware packages: Handled by hardware modules
  #   - can-utils → pican2-duo.nix
  #   - i2c-tools → pican2-duo.nix
  #   - libraspberrypi, raspberrypi-eeprom → raspberry-pi.nix
  # - Common utilities (vim, git, curl, wget): Already in home/_modules/shell/
  # - Python packages: In home/ryan/hosts/nixpi.nix for RVC development
}
