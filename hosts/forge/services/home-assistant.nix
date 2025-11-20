{ config, pkgs, ... }:
{
  config = {
    modules.services.home-assistant = {
      enable = true;

      # Expose only via Caddy; rely on Home Assistant's native authentication flows
      reverseProxy = {
        enable = true;
        hostName = "ha.${config.networking.domain}";
      };

      # Keep Home Assistant UI-managed while placing all data on ZFS
      dataDir = "/var/lib/home-assistant";
      port = 8123;

      # Nightly backups with snapshot coordination (SQLite databases)
      backup = {
        enable = true;
        repository = "nas-primary";
        useSnapshots = true;
        zfsDataset = "tank/services/home-assistant";
        frequency = "daily";
        tags = [ "home-automation" "home-assistant" "forge" ];
      };

      # Upstream nixpkgs is currently missing several runtime dependencies
      # required by Home Assistant's default_config bundle. Provide them here
      # until the packaged closure includes the Python wheels directly.
      extraPackages = python3Packages:
        with python3Packages;
        [
          aiodiscover
          aiodhcpwatcher
          aiousbwatcher
          (python3Packages."async-upnp-client")
          av
          (python3Packages."go2rtc-client")
          isal
          pyserial
          pynacl
          (python3Packages."zlib-ng")
        ];

      extraLibs = with pkgs; [ zlib-ng isa-l ];
    };
  };
}
