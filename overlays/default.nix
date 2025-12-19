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
  #
  # WORKAROUNDS: See docs/workarounds.md for tracking of temporary fixes
  unstable-packages = final: _prev: {
    unstable = import inputs.nixpkgs-unstable {
      system = final.stdenv.hostPlatform.system;
      config.allowUnfree = true;
      overlays = [
        # Overlays of unstable packages are declared here
        # NOTE: Temporary workarounds should be documented in docs/workarounds.md
        (_final: prev: {
          # WORKAROUND: kubectl-node-shell platform restrictions
          # Removes platform meta to allow installation on all systems
          kubectl-node-shell = prev.kubectl-node-shell.overrideAttrs (_: prevAttrs: {
            meta = builtins.removeAttrs prevAttrs.meta [ "platforms" ];
          });

          # WORKAROUND: kubectl-view-secret incorrect binary name
          # Upstream packages binary as 'cmd' instead of expected name
          kubectl-view-secret = prev.kubectl-view-secret.overrideAttrs (_: _prevAttrs: {
            postInstall = ''
              mv $out/bin/cmd $out/bin/kubectl-view_secret
            '';
          });

          pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
            (_pyFinal: pyPrev: {
              # WORKAROUND (2025-12-19): aio-georss-client test failure with Python 3.13
              # Tests fail in test_feed.py due to Python 3.13 compatibility issues
              # Check: When aio-georss-client is updated or Python 3.14 releases
              aio-georss-client = pyPrev.aio-georss-client.overridePythonAttrs (old: {
                doCheck = false;
                meta = old.meta // { broken = false; };
              });

              # WORKAROUND (2025-12-19): granian HTTPS tests fail in Nix sandbox
              # Tests use self-signed certs that fail SSL verification during build
              # Affects: home-assistant (uses granian indirectly)
              # Check: When granian is updated in nixpkgs-unstable
              granian = pyPrev.granian.overridePythonAttrs (old: {
                disabledTestPaths = (old.disabledTestPaths or [ ]) ++ [
                  "tests/test_https.py"
                ];
              });
            })
          ];
        })
      ];
    };
  };

  # Your own overlays for stable nixpkgs should be declared here
  # NOTE: Temporary workarounds should be documented in docs/workarounds.md
  nixpkgs-overlays = final: prev: {
    # Custom Caddy build with Cloudflare DNS provider and caddy-security plugins
    # See pkgs/caddy-custom.nix for plugin configuration and hash updates
    caddy = import ../pkgs/caddy-custom.nix { pkgs = final.unstable; };

    # WORKAROUND (2025-12-19): granian HTTPS tests fail in Nix sandbox
    # Tests use self-signed certs that fail SSL verification during build
    # Affects: paperless-ngx (uses granian as ASGI server)
    # Check: When granian is updated in stable nixpkgs
    # See: docs/workarounds.md for full tracking
    pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
      (_pyFinal: pyPrev: {
        granian = pyPrev.granian.overridePythonAttrs (old: {
          disabledTestPaths = (old.disabledTestPaths or [ ]) ++ [
            "tests/test_https.py"
          ];
        });
      })
    ];
  };
}
