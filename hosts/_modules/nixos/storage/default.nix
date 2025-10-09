# /hosts/_modules/nixos/storage/default.nix
{
  imports = [
    ./datasets.nix
    ./nfs-mounts.nix
    ./sanoid.nix
  ];
}
