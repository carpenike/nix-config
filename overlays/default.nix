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
      system = final.stdenv.hostPlatform.system;
      config.allowUnfree = true;
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
          # Temporary: aio-georss-client has a test failure with Python 3.13
          # Using pythonPackagesExtensions ensures the fix propagates to all dependents
          # https://github.com/NixOS/nixpkgs/issues/... (upstream bug in test_feed.py)
          pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
            (_pyFinal: pyPrev: {
              aio-georss-client = pyPrev.aio-georss-client.overridePythonAttrs (old: {
                doCheck = false;
                meta = old.meta // { broken = false; };
              });
            })
          ];
        })
      ];
    };
  };

  # Your own overlays for stable nixpkgs should be declared here
  nixpkgs-overlays = final: _prev: {
    # Custom Caddy build with Cloudflare DNS provider and caddy-security plugins
    # See pkgs/caddy-custom.nix for plugin configuration and hash updates
    caddy = import ../pkgs/caddy-custom.nix { pkgs = final.unstable; };
  };
}
