# SD-image variant for nixpi: builds a flashable image with a 512 MiB firmware
# (/boot) partition so the kernel fits. Swaps the installed-system fileSystems
# for the sd-image module's partitioning. Build with:
#   nix build .#nixosConfigurations.nixpi-image.config.system.build.sdImage
# (aarch64 builds offload to the Mac linux-builder; image lands in result/sd-image)
{ modulesPath, ... }:
{
  imports = [ "${modulesPath}/installer/sd-card/sd-image-aarch64.nix" ];
  disabledModules = [ ./hardware-configuration.nix ];

  sdImage = {
    firmwareSize = 512; # MiB — up from the 30 default; holds the 36 MB kernel
    compressImage = false; # flash result/sd-image/*.img directly
  };
}
