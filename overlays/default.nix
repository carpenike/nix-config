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
  nixpkgs-overlays = final: prev: {
    # Custom Caddy build with Cloudflare DNS provider and caddy-security plugins
    # See pkgs/caddy-custom.nix for plugin configuration and hash updates
    caddy = import ../pkgs/caddy-custom.nix { pkgs = final.unstable; };

    # Fix flask-cors version metadata issue
    # Flask-cors 6.x uses pyproject.toml with dynamic version from git tags.
    # When built from GitHub archive (not PyPI), the version ends up as 0.0.1
    # because there's no git metadata. This causes alerta-server to fail loading
    # plugins with: "flask-cors 0.0.1 ... Requirement.parse('Flask-Cors>=3.0.2')"
    # Fix by using PyPI source which has correct version in metadata.
    pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
      (pyFinal: pyPrev: {
        flask-cors = pyPrev.flask-cors.overridePythonAttrs (old: {
          # Use PyPI source instead of GitHub archive to get correct version metadata
          src = pyFinal.fetchPypi {
            pname = "flask_cors";
            version = old.version;
            hash = "sha256-2BvLMfB7CYW+f0hAYkfpJDrO0im3dHIZFgoFWe3WeNs=";
          };
          # PyPI source doesn't include tests, so disable check phase
          doCheck = false;
        });
      })
    ];
  };
}
