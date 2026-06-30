# Impermanence: ESP32-style appliance. Root (/) is tmpfs and wiped every boot;
# only the paths below survive, bind-mounted from /persist on the USB SSD so the
# SD card sees ~zero runtime writes. /nix (SD) holds the immutable store.
{ ... }:
{
  environment.persistence."/persist" = {
    hideMounts = true;
    directories = [
      "/var/lib/nixos" # uid/gid map stability
      "/var/lib/systemd" # timers, random seed
      "/var/lib/iwd" # wifi credentials/state
    ];
    files = [
      "/etc/machine-id"
      "/etc/ssh/ssh_host_ed25519_key"
      "/etc/ssh/ssh_host_ed25519_key.pub"
      "/etc/ssh/ssh_host_rsa_key"
      "/etc/ssh/ssh_host_rsa_key.pub"
    ];
  };
}
