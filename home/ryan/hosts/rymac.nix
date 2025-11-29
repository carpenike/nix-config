{ ...
}:
{
  modules = {
    deployment.nix.enable = true;
    development.enable = true;
    kubernetes.enable = true;
    security.gnugpg.enable = true;
  };
}
