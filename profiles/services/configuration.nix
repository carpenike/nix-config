{ userSettings, ... }:

{
  # imports = [ ./base.nix
  #             ( import ../../system/security/sshd.nix {
  #               authorizedKeys = [ "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBOslNYCKlAhgO9vxUVt4Vq0diz35JD0f6Vtdh2zfZwyb+SI/TPC+U06TPsxS++KN+HHkQvNBcqpQ6a8qNsYsVJA="];
  #               inherit userSettings; })
  #           ];
  imports = [];
}
