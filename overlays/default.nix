{
  inputs,
  ...
}:
{
  rust-overlay = inputs.rust-overlay.overlays.default;

  additions = final: _prev:
    import ../pkgs {
      inherit inputs;
      pkgs = final;
    };

  # The unstable nixpkgs set (declared in the flake inputs) will
  # be accessible through `pkgs.unstable`
  unstable-packages = final: prev: {
    unstable = import inputs.nixpkgs-unstable {
      inherit (final) system;
      config.allowUnfree = true;
      overlays = [
        # overlays of unstable packages are declared here
        (final: prev: {
          kubectl-node-shell = prev.kubectl-node-shell.overrideAttrs (_: prev: {
            meta = builtins.removeAttrs prev.meta ["platforms"];
          });
          kubectl-view-secret = prev.kubectl-view-secret.overrideAttrs (_: prev: {
            postInstall = ''
              mv $out/bin/cmd $out/bin/kubectl-view_secret
            '';
          });
        })
      ];
    };
  };

  # Your own overlays for stable nixpkgs should be declared here
  nixpkgs-overlays = final: prev: {
    # Custom Caddy build with Cloudflare DNS plugin for nixpi
    caddy = final.unstable.caddy.withPlugins {
      # Include Cloudflare DNS provider plugin
      # Using latest v0.2.1 release
      plugins = [ "github.com/caddy-dns/cloudflare@v0.2.1" ];
      # Let Nix calculate the hash - will fail first time with correct hash
      hash = "sha256-XwZ0Hkeh2FpQL/fInaSq+/3rCLmQRVvwBM0Y1G1FZNU=";
    };
  };
}
