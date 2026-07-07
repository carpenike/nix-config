{ lib
, config
, ...
}:
let
  cfg = config.modules.services.openssh;
in
{
  options.modules.services.openssh = {
    enable = lib.mkEnableOption "openssh";
  };

  config = lib.mkIf cfg.enable {
    services.openssh = {
      enable = true;
      openFirewall = true;
      # TODO: Enable this when option becomes available
      # Don't allow home-directory authorized_keys
      # authorizedKeysFiles = lib.mkForce ["/etc/ssh/authorized_keys.d/%u"];
      settings = {
        # Harden
        PasswordAuthentication = false;
        PermitRootLogin = "no";
        # Automatically remove stale sockets (needed for the GPG agent
        # socket RemoteForward from rymac - see home/ryan/hosts/rymac.nix)
        StreamLocalBindUnlink = "yes";
        # GatewayPorts deliberately left at the default ("no"): remote TCP
        # forwards bind loopback only. The GPG socket forward above is a unix
        # socket forward and does not need GatewayPorts.
      };
    };

    # Passwordless sudo when SSH'ing with keys
    security.pam.sshAgentAuth.enable = true;
    # TODO: Enable this when option becomes available
    # security.pam.sshAgentAuth = {
    #   enable = true;
    #   authorizedKeysFiles = [
    #     "/etc/ssh/authorized_keys.d/%u"
    #   ];
    # };
  };
}
