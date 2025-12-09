# Declares Cloudflare R2 configuration for offsite backups
# Used by pgBackRest, Restic, and other backup systems
{ lib, ... }:
{
  options.my.r2 = {
    endpoint = lib.mkOption {
      type = lib.types.str;
      description = "Cloudflare R2 S3-compatible endpoint";
      example = "21ee32956d11b5baf662d186bd0b4ab4.r2.cloudflarestorage.com";
    };

    bucket = lib.mkOption {
      type = lib.types.str;
      description = "R2 bucket name for offsite backups";
      example = "nix-homelab-prod-servers";
    };
  };
}
