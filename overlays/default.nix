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
  unstable-packages = final: _prev: {
    unstable = import inputs.nixpkgs-unstable {
      inherit (final) system;
      config.allowUnfree = true;
      config.allowBroken = true; # Temporary: python3.13-aio-georss-client broken in nixpkgs-unstable
      overlays = [
        # overlays of unstable packages are declared here
        (_final: prev: {
          kubectl-node-shell = prev.kubectl-node-shell.overrideAttrs (_: prevAttrs: {
            meta = builtins.removeAttrs prevAttrs.meta [ "platforms" ];
          });
          kubectl-view-secret = prev.kubectl-view-secret.overrideAttrs (_: _prevAttrs: {
            postInstall = ''
              mv $out/bin/cmd $out/bin/kubectl-view_secret
            '';
          });
        })
      ];
    };
  };

  # Your own overlays for stable nixpkgs should be declared here
  nixpkgs-overlays = final: _prev: {
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
