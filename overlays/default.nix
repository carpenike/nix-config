{ inputs
, ...
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
            meta = builtins.removeAttrs prev.meta [ "platforms" ];
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
    # Custom Caddy build with Cloudflare DNS provider and caddy-security plugins
    # Note: When Renovate updates plugin versions, manually update the hash
    caddy = final.unstable.caddy.withPlugins {
      plugins = [
        # renovate: depName=github.com/caddy-dns/cloudflare datasource=go
        "github.com/caddy-dns/cloudflare@v0.2.2"
        # renovate: depName=github.com/greenpau/caddy-security datasource=go
        "github.com/greenpau/caddy-security@v1.1.31"
      ];
      hash = "sha256-jVL3AR0EzAg35M+U5dCdcUNFPgLNOsmzUmzqqttVZwk=";
    };
  };
}
