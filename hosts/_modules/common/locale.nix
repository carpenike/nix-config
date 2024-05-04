{
  lib,
  ...
}: {
  time.timeZone = lib.mkDefault "America/New_York";
  environment .variables = {
    LANG = "en_US.UTF-8";
    LC_ALL = "en_US.UTF-8";
  };
}
