{ runtime }:
{
  extraConfig = ''
    @atrium_private path /cc/issue /cc/issue/* /v1/native-policy /v1/native-policy/* /v1/devices/register /v1/devices/register/*
    respond @atrium_private 404
  '';
  reverseProxyBlock = (import ./headers.nix) + ''
    transport http {
      network_proxy none
      compression off
    }
  '';
  backend = {
    host = "127.0.0.1";
    port = runtime.ports.resolver;
  };
}
