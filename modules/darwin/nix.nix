_:
{
  # Fix for NixOS 25.05 - Nix build group GID changed from 30000 to 350
  ids.gids.nixbld = 350;

  nix.gc = {
    automatic = true;

    interval = {
      Weekday = 0;
      Hour = 2;
      Minute = 0;
    };
  };

  # nix-daemon is now managed unconditionally by nix-darwin when nix.enable is on

  nix.settings = {
    trusted-users = [ "root" "ryan" ];
    ssl-cert-file = "/nix/var/nix/profiles/default/etc/ssl/certs/ca-bundle.crt";
  };

  # Linux remote builder VM. On Apple Silicon this boots a lightweight NixOS
  # aarch64-linux guest under Apple's Virtualization framework (via QEMU), so
  # this Mac can build aarch64-linux closures (e.g. the nixpi Raspberry Pi
  # system) at *native* speed and push them to the target — instead of
  # compiling on the Pi itself. The builder image is substitutable from
  # cache.nixos.org, so enabling this does not require an existing Linux
  # builder to bootstrap.
  #
  # Pair with `task nix:deploy-nixos host=nixpi` to build here and deploy.
  nix.linux-builder = {
    enable = true;
    # Wipe the guest's /nix/store on each restart to avoid stale build state.
    ephemeral = true;
    config = {
      # cores/memory/disk are host-side QEMU runtime args, so they can be tuned
      # without rebuilding the substituted guest image.
      virtualisation = {
        cores = 6;
        # Headroom for big builds: RPi kernel scratch (~18G) + SD-image
        # assembly (ext4 + .img + chroot). qcow2 is sparse, so this is a cap.
        darwin-builder.diskSize = 200 * 1024; # MiB
        darwin-builder.memorySize = 8 * 1024; # MiB
      };
    };
  };
}
