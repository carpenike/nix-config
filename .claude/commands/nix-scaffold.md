# /nix-scaffold

Generate boilerplate files for new modules or hosts with proper conventions.

## Usage

```
/nix-scaffold type=<module|host> name=<name> [layer=<common|nixos|darwin>]
```

## Parameters

- `type` (required): What to scaffold (`module` or `host`)
- `name` (required): Name of the module or host
- `layer` (optional): Module layer - `common` (default), `nixos`, or `darwin`

## Examples

```bash
# Create a new common module
/nix-scaffold type=module name=tailscale

# Create NixOS-specific module
/nix-scaffold type=module name=bind layer=nixos

# Create Darwin-specific module
/nix-scaffold type=module name=homebrew layer=darwin

# Create new host configuration
/nix-scaffold type=host name=newserver
```

## Implementation

### Module Scaffolding

#### Common Module (`/nix-scaffold type=module name=tailscale layer=common`)

**Creates**: `hosts/_modules/common/tailscale/default.nix`

```nix
{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.tailscale;
in
{
  options.services.tailscale = {
    enable = mkEnableOption "Enable Tailscale service";

    # Add more options here as needed
    # Example:
    # authKey = mkOption {
    #   type = types.str;
    #   description = "Tailscale auth key";
    # };
  };

  config = mkIf cfg.enable {
    # Add configuration here
    # Example:
    # services.tailscale.enable = true;
    # environment.systemPackages = [ pkgs.tailscale ];
  };
}
```

**Reminder**: Add import to `hosts/_modules/common/default.nix`

#### NixOS Module (`/nix-scaffold type=module name=bind layer=nixos`)

**Creates**: `hosts/_modules/nixos/services/bind/default.nix`

```nix
{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.bind-custom;
in
{
  options.services.bind-custom = {
    enable = mkEnableOption "Enable custom BIND DNS server configuration";

    # Add NixOS-specific options
    # zones = mkOption {
    #   type = types.attrsOf types.str;
    #   default = {};
    #   description = "DNS zones configuration";
    # };
  };

  config = mkIf cfg.enable {
    # NixOS-specific configuration
    # services.bind = {
    #   enable = true;
    #   # Additional BIND configuration
    # };

    # networking.firewall.allowedUDPPorts = [ 53 ];
    # networking.firewall.allowedTCPPorts = [ 53 ];
  };
}
```

#### Darwin Module (`/nix-scaffold type=module name=homebrew layer=darwin`)

**Creates**: `hosts/_modules/darwin/homebrew/default.nix`

```nix
{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.homebrew-custom;
in
{
  options.homebrew-custom = {
    enable = mkEnableOption "Enable custom Homebrew configuration";

    # Darwin-specific options
    # extraCasks = mkOption {
    #   type = types.listOf types.str;
    #   default = [];
    #   description = "Additional Homebrew casks to install";
    # };
  };

  config = mkIf cfg.enable {
    # Darwin-specific configuration
    # homebrew = {
    #   enable = true;
    #   casks = cfg.extraCasks;
    # };
  };
}
```

### Host Scaffolding

#### New Host (`/nix-scaffold type=host name=newserver`)

**Creates**: `hosts/newserver/default.nix`

```nix
{ config, lib, pkgs, inputs, hostname, ... }:

{
  # Import host-specific modules
  imports = [
    # Add hardware configuration if needed
    # ./hardware-configuration.nix

    # Add host-specific modules
    # ./services.nix
    # ./networking.nix
  ];

  # Host-specific configuration
  networking.hostName = "newserver";

  # System configuration
  # networking.interfaces.eth0.ipv4.addresses = [
  #   { address = "192.168.1.100"; prefixLength = 24; }
  # ];

  # Services specific to this host
  # services.nginx.enable = true;

  # User configuration
  # users.users.ryan = {
  #   isNormalUser = true;
  #   extraGroups = [ "wheel" ];
  # };
}
```

**Reminder**: Add to `nixosConfigurations` in `flake.nix`:

```nix
newserver = mkSystemLib.mkNixosSystem "x86_64-linux" "newserver";
```

## Directory Structure

### Modules
- **Common**: `hosts/_modules/common/<name>/default.nix`
- **NixOS**: `hosts/_modules/nixos/services/<name>/default.nix`
- **Darwin**: `hosts/_modules/darwin/<name>/default.nix`

### Hosts
- **Host config**: `hosts/<name>/default.nix`
- **Hardware**: `hosts/<name>/hardware-configuration.nix` (if needed)
- **Secrets**: `hosts/<name>/secrets.sops.yaml` (if needed)

## Post-Scaffold Steps

### For Modules
1. **Add import** to appropriate `default.nix` file
2. **Implement options** and configuration logic
3. **Test with**: `/nix-validate`
4. **Enable in host** configuration

### For Hosts
1. **Add to flake.nix** in appropriate configurations section
2. **Configure hardware** if physical host
3. **Set up secrets** if needed with `/sops-edit`
4. **Validate**: `/nix-validate host=<hostname>`
5. **Test deployment**: `/nix-deploy host=<hostname> --build-only`

## Notes

- Follow existing patterns in the repository
- Use consistent naming conventions
- Add comprehensive options and documentation
- Test thoroughly before committing
- Consider security implications for new services
