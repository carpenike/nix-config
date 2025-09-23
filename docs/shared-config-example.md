# Shared Configuration Example

This document demonstrates how to use the new shared configuration pattern implemented for BIND DNS.

## Current Usage (Luna)

```nix
# hosts/luna/default.nix
modules.services.bind = {
  enable = true;
  shared.enable = true; # Use shared holthome.net configuration
};
```

## Future Host Customization Example (Rydev)

```nix
# hosts/rydev/default.nix (example for future use)
modules.services.bind = {
  enable = true;
  shared = {
    enable = true;

    # Host-specific additions without duplicating shared config
    extraConfig = ''
      # Development-specific DNS settings
      also-notify { 192.168.1.5; };
    '';

    extraZones = {
      "dev.holthome.net." = ''
        type master;
        file "/etc/bind/zones/dev.holthome.net";
      '';
    };

    # Customize network access
    networks.trusted = [
      "10.10.0.0/16"   # LAN (inherited from default)
      "10.20.0.0/16"   # Servers (inherited from default)
      "10.30.0.0/16"   # WIRELESS (inherited from default)
      "10.40.0.0/16"   # IoT (inherited from default)
      "192.168.1.0/24" # Dev network (added)
    ];

    # Enable debug logging for development
    logging.severity = "debug";
  };
};
```

## Benefits

1. **No Configuration Duplication**: Shared logic in one place
2. **Host-Specific Customization**: Easy to add per-host settings
3. **Consistent Base Configuration**: All hosts get the same foundation
4. **Maintainable**: Updates to shared config apply everywhere
5. **Declarative**: All configuration is explicit and version-controlled

## Pattern Applied

This pattern eliminates the duplicate `bind.nix` files that were identical between luna and rydev, while providing flexibility for future host-specific customization.
