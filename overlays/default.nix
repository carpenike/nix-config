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

          # WORKAROUND (2025-01-01): ctranslate2 missing #include <cstdint> in cxxopts.hpp
          # C++20/GCC 14 requires explicit cstdint include for uint8_t
          # Affects: open-webui (via faster-whisper -> ctranslate2)
          # Upstream: https://github.com/OpenNMT/CTranslate2/issues/XXX
          # Check: When ctranslate2 >= 4.7.0 or upstream fixes cxxopts
          ctranslate2 = prev.ctranslate2.overrideAttrs (old: {
            postPatch = (old.postPatch or "") + ''
              # Add missing #include <cstdint> to cxxopts.hpp for C++20 compatibility
              # Insert after the #ifndef guard and before other includes
              sed -i '/#ifndef CXXOPTS_HPP_INCLUDED/a #include <cstdint>' third_party/cxxopts/include/cxxopts.hpp
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

              # WORKAROUND (2025-01-01): duckdb-engine tests fail with pg_collation error
              # Tests use SQLAlchemy reflection that queries pg_collation which doesn't exist in DuckDB
              # Affects: open-webui (via langchain-community)
              # Upstream: https://github.com/Mause/duckdb_engine/issues/XXX
              # Check: When duckdb-engine >= 0.18.0 or test suite is fixed
              duckdb-engine = pyPrev.duckdb-engine.overridePythonAttrs (_old: {
                doCheck = false;
              });

              # WORKAROUND (2025-01-01): langchain-community tests require network access
              # Tests try to connect to api.smith.langchain.com which fails in Nix sandbox
              # Affects: open-webui
              # Check: When langchain-community tests are fixed to not require network
              langchain-community = pyPrev.langchain-community.overridePythonAttrs (_old: {
                doCheck = false;
              });

              # WORKAROUND (2025-01-01): extract-msg beautifulsoup4 version constraint too strict
              # Package requires beautifulsoup4<4.14 but nixpkgs has 4.14.3
              # Affects: open-webui (indirect dependency)
              # Check: When extract-msg is updated to allow newer beautifulsoup4
              extract-msg = pyPrev.extract-msg.overridePythonAttrs (_old: {
                pythonRelaxDeps = [ "beautifulsoup4" ];
              });

              # WORKAROUND (2025-01-01): weatherflow4py marshmallow version constraint too strict
              # Package requires marshmallow<4.0.0 but nixpkgs has 4.1.0
              # Affects: home-assistant
              # Check: When weatherflow4py is updated to allow newer marshmallow
              weatherflow4py = pyPrev.weatherflow4py.overridePythonAttrs (_old: {
                pythonRelaxDeps = [ "marshmallow" ];
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

    # WORKAROUND (2026-01-09): thelounge sqlite3 native module removed in postInstall
    # nixpkgs thelounge package builds sqlite3 correctly but then deletes the build/
    # directory in postInstall, breaking the native module at runtime
    # Error: "[ERROR] Unable to load sqlite3 module"
    # Affects: Message history persistence (scrollback not saved between restarts)
    # Upstream: https://github.com/NixOS/nixpkgs (should file bug)
    # Check: When nixpkgs thelounge package removes the erroneous postInstall rm
    thelounge = prev.thelounge.overrideAttrs (_old: {
      postInstall = ""; # Don't delete the sqlite3 build directory!
    });

    # WORKAROUND (2025-01-01): ctranslate2 missing #include <cstdint> in cxxopts.hpp
    # C++20/GCC 14 requires explicit cstdint include for uint8_t
    # Affects: open-webui (via faster-whisper -> ctranslate2)
    # Check: When ctranslate2 >= 4.7.0 or upstream fixes cxxopts
    ctranslate2 = prev.ctranslate2.overrideAttrs (old: {
      postPatch = (old.postPatch or "") + ''
        # Add missing #include <cstdint> to cxxopts.hpp for C++20 compatibility
        sed -i '/#include <optional>/a #include <cstdint>' third_party/cxxopts/include/cxxopts.hpp
      '';
    });

    pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
      (_pyFinal: pyPrev: {
        # WORKAROUND (2025-12-19): granian HTTPS tests fail in Nix sandbox
        # Tests use self-signed certs that fail SSL verification during build
        # Affects: paperless-ngx (uses granian as ASGI server)
        # Check: When granian is updated in stable nixpkgs
        # See: docs/workarounds.md for full tracking
        granian = pyPrev.granian.overridePythonAttrs (old: {
          disabledTestPaths = (old.disabledTestPaths or [ ]) ++ [
            "tests/test_https.py"
          ];
        });

        # WORKAROUND (2025-01-01): duckdb-engine tests fail with pg_collation error
        # Tests use SQLAlchemy reflection that queries pg_collation which doesn't exist in DuckDB
        # Affects: open-webui (via langchain-community)
        # Check: When duckdb-engine >= 0.18.0 or test suite is fixed
        duckdb-engine = pyPrev.duckdb-engine.overridePythonAttrs (_old: {
          doCheck = false;
        });

        # WORKAROUND (2025-01-01): langchain-community tests require network access
        # Tests try to connect to api.smith.langchain.com which fails in Nix sandbox
        # Affects: open-webui
        # Check: When langchain-community tests are fixed to not require network
        langchain-community = pyPrev.langchain-community.overridePythonAttrs (_old: {
          doCheck = false;
        });

        # WORKAROUND (2025-01-01): extract-msg beautifulsoup4 version constraint too strict
        # Package requires beautifulsoup4<4.14 but nixpkgs has 4.14.3
        # Affects: open-webui (indirect dependency)
        # Check: When extract-msg is updated to allow newer beautifulsoup4
        extract-msg = pyPrev.extract-msg.overridePythonAttrs (_old: {
          pythonRelaxDeps = [ "beautifulsoup4" ];
        });

        # WORKAROUND (2025-01-01): weatherflow4py marshmallow version constraint too strict
        # Package requires marshmallow<4.0.0 but nixpkgs has 4.1.0
        # Affects: home-assistant
        # Check: When weatherflow4py is updated to allow newer marshmallow
        weatherflow4py = pyPrev.weatherflow4py.overridePythonAttrs (_old: {
          pythonRelaxDeps = [ "marshmallow" ];
        });
      })
    ];
  };
}
