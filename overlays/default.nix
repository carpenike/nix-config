{ inputs
, ...
}:
let
  # ===========================================================================
  # Shared overrides used by BOTH the unstable and stable channels.
  # Centralising them here ensures the two channels never silently diverge
  # (e.g. one channel having a fix the other doesn't). Channel-specific
  # workarounds (typically tied to a particular Python version) stay inline
  # in their respective overlay below.
  #
  # NOTE: All workarounds here must also be tracked in docs/workarounds.md.
  # ===========================================================================

  # WORKAROUND (2025-01-01): ctranslate2 missing #include <cstdint> in cxxopts.hpp
  # C++20 / GCC 14 require an explicit cstdint include for uint8_t. Insertion
  # is anchored to the cxxopts include-guard so it works regardless of which
  # other headers the bundled cxxopts.hpp happens to include.
  # Affects: open-webui (via faster-whisper -> ctranslate2), paperless (transitive)
  # Upstream: https://github.com/OpenNMT/CTranslate2 (no specific tracking issue;
  #   the bundled cxxopts.hpp dependency is the actual offender)
  # Check: When ctranslate2 >= 4.7.0 or upstream fixes cxxopts
  ctranslate2Override = prev: prev.ctranslate2.overrideAttrs (old: {
    postPatch = (old.postPatch or "") + ''
      # Add missing #include <cstdint> to cxxopts.hpp for C++20 compatibility.
      sed -i '/#ifndef CXXOPTS_HPP_INCLUDED/a #include <cstdint>' third_party/cxxopts/include/cxxopts.hpp
    '';
  });

  # Shared Python override fragment applied to both stable and unstable
  # `pythonPackagesExtensions`. Defined as a single attrset so adding a new
  # workaround applies to both channels in one edit.
  sharedPythonOverrides = pyFinal: pyPrev: {
    # CUSTOM PACKAGE (2026-01-26): thermoworks-cloud
    # Python API client for ThermoWorks Cloud devices (Signals BBQ thermometer, etc.)
    # Required by: home-assistant thermoworks_cloud integration
    # Upstream: https://github.com/a2hill/python-thermoworks-cloud
    # Check: When thermoworks-cloud lands in nixpkgs
    thermoworks-cloud = pyFinal.buildPythonPackage rec {
      pname = "thermoworks-cloud";
      version = "0.1.12";
      pyproject = true;

      src = pyFinal.fetchPypi {
        pname = "thermoworks_cloud";
        inherit version;
        hash = "sha256-6PNBuLOS1i6pVjswoOPYORgzC2/wFwIJFh3zE9PFpxw=";
      };

      build-system = [
        pyFinal.setuptools
        pyFinal.setuptools-scm
      ];
      dependencies = [ pyFinal.aiohttp ];
      doCheck = false;
      pythonImportsCheck = [ "thermoworks_cloud" ];

      # Use inputs.nixpkgs.lib (constants only) to avoid capturing the outer
      # overlay's `prev` from inside this shared fragment.
      meta = with inputs.nixpkgs.lib; {
        description = "Python API client for ThermoWorks Cloud devices";
        homepage = "https://github.com/a2hill/python-thermoworks-cloud";
        license = licenses.gpl3;
      };
    };

    # WORKAROUND (2025-12-19, escalated 2026-05-13): granian tests are unreliable in Nix sandbox.
    # Originally only HTTPS tests failed (self-signed cert / SSL verification in sandbox).
    # On 2026-05-13 the test suite hung forge's nixos-upgrade.service for 3.5 days inside
    # a non-HTTPS test (most likely a network-dependent socket test waiting on a timeout).
    # Granian is an ASGI server — its functional behavior is exercised by paperless/HA at
    # runtime; running its upstream pytest suite during the Nix build provides no extra
    # safety while introducing a hard availability risk for every host that consumes it.
    # Affects: home-assistant (transitive), paperless-ngx (uses granian as ASGI server)
    # Check: When granian is updated in nixpkgs and upstream tests are sandbox-friendly.
    granian = pyPrev.granian.overridePythonAttrs (_old: {
      doCheck = false;
    });

    # WORKAROUND (2025-01-01): duckdb-engine tests fail with pg_collation error
    # Tests use SQLAlchemy reflection that queries pg_collation which doesn't
    # exist in DuckDB.
    # Affects: open-webui (via langchain-community)
    # Upstream: https://github.com/Mause/duckdb_engine (no single tracking issue;
    #   reflection vs DuckDB system catalogs is a known design gap)
    # Check: When duckdb-engine >= 0.18.0 or test suite is fixed
    duckdb-engine = pyPrev.duckdb-engine.overridePythonAttrs (_old: {
      doCheck = false;
    });

    # WORKAROUND (2025-01-01): langchain-community tests require network access
    # Tests try to connect to api.smith.langchain.com which fails in Nix sandbox.
    # Affects: open-webui
    # Check: When langchain-community tests are fixed to not require network
    langchain-community = pyPrev.langchain-community.overridePythonAttrs (_old: {
      doCheck = false;
    });

    # WORKAROUND (2025-01-01): extract-msg beautifulsoup4 version constraint too strict
    # Package requires beautifulsoup4<4.14 but nixpkgs has 4.14.3.
    # Affects: open-webui (indirect dependency)
    # Check: When extract-msg is updated to allow newer beautifulsoup4
    extract-msg = pyPrev.extract-msg.overridePythonAttrs (_old: {
      pythonRelaxDeps = [ "beautifulsoup4" ];
    });

    # WORKAROUND (2025-01-01): weatherflow4py marshmallow version constraint too strict
    # Package requires marshmallow<4.0.0 but nixpkgs has 4.1.0.
    # Affects: home-assistant
    # Check: When weatherflow4py is updated to allow newer marshmallow
    weatherflow4py = pyPrev.weatherflow4py.overridePythonAttrs (_old: {
      pythonRelaxDeps = [ "marshmallow" ];
    });
  };
in
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

          # Shared with stable channel - see top of file.
          ctranslate2 = ctranslate2Override prev;

          pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
            # Shared overrides applied to both channels
            sharedPythonOverrides

            # Unstable-only Python overrides:
            # - Custom buildPythonPackage definitions tied to Home Assistant on
            #   unstable (homekit-audio-proxy, aioacaia)
            # - Python 3.14 transition issues not yet present in stable, which
            #   still defaults to Python 3.13 (aiounittest, httpx-auth, ics, ...)
            (pyFinal: pyPrev: {
              # CUSTOM PACKAGE (2026-05-07): homekit-audio-proxy
              # SRTP audio proxy for HomeKit camera streaming. Required runtime
              # dep of Home Assistant 2026.4's homekit integration
              # (homeassistant/components/homekit/type_cameras.py imports it at
              # module top, so the entire HASS Bridge fails to start without it).
              # Required by: home-assistant homekit integration (Apple Home bridge)
              # Upstream: https://github.com/bdraco/homekit-audio-proxy
              # Check: When homekit-audio-proxy lands in nixpkgs
              homekit-audio-proxy = pyFinal.buildPythonPackage rec {
                pname = "homekit-audio-proxy";
                version = "1.2.1";
                pyproject = true;

                src = pyFinal.fetchPypi {
                  pname = "homekit_audio_proxy";
                  inherit version;
                  hash = "sha256-nGX1f8xOLFnxF7uk2sMyYPRdFdfKJuohWANb0UT9VJU=";
                };

                build-system = [ pyFinal.setuptools ];
                dependencies = [ pyFinal.cryptography ];
                doCheck = false;
                pythonImportsCheck = [ "homekit_audio_proxy" ];

                meta = with prev.lib; {
                  description = "SRTP audio proxy for HomeKit camera streaming";
                  homepage = "https://github.com/bdraco/homekit-audio-proxy";
                  license = licenses.asl20;
                };
              };

              # CUSTOM PACKAGE (2026-05-07): aioacaia
              # Async Bluetooth client for Acaia coffee scales. Required by
              # Home Assistant's built-in `acaia` integration; without it the
              # integration raises ModuleNotFoundError when its config flow
              # is opened.
              # Required by: home-assistant acaia integration
              # Upstream: https://github.com/zweckj/aioacaia
              # Check: When aioacaia lands in nixpkgs
              aioacaia = pyFinal.buildPythonPackage rec {
                pname = "aioacaia";
                version = "0.1.18";
                pyproject = true;

                src = pyFinal.fetchPypi {
                  inherit pname version;
                  hash = "sha256-KjCBDA+jScqMw9artTcykKxsGkRtOtkvOnist0dvsqc=";
                };

                build-system = [ pyFinal.setuptools ];
                dependencies = [
                  pyFinal.bleak
                  pyFinal.bleak-retry-connector
                ];
                doCheck = false;
                pythonImportsCheck = [ "aioacaia" ];

                meta = with prev.lib; {
                  description = "Async implementation of pyacaia for Acaia smart scales";
                  homepage = "https://github.com/zweckj/aioacaia";
                  license = licenses.agpl3Only;
                };
              };

              # WORKAROUND (2025-12-19): aio-georss-client test failure with Python 3.13+
              # Tests fail in test_feed.py due to Python compatibility issues
              # Check: When aio-georss-client is updated
              aio-georss-client = pyPrev.aio-georss-client.overridePythonAttrs (old: {
                doCheck = false;
                meta = old.meta // { broken = false; };
              });

              # WORKAROUND (2026-04-28): aiounittest disabled on Python 3.14 in nixpkgs
              # Upstream nixpkgs marks aiounittest 1.5.0 as `disabled = pythonAtLeast "3.14"`
              # because its own test suite fails on 3.14. The library itself works fine
              # at runtime - the package is a legacy pre-3.8 async-test shim that
              # IsolatedAsyncioTestCase superseded years ago, but several home-assistant
              # transitive deps still list it as a check input.
              # Without this override, the entire forge/luna closure fails to evaluate
              # whenever python3 default is 3.14.
              # Affects: home-assistant (transitive test dep)
              # Upstream: https://github.com/kwarunek/aiounittest/issues/28
              # Check: When aiounittest > 1.5.0 lands or nixpkgs un-disables.
              aiounittest = pyPrev.aiounittest.overridePythonAttrs (old: {
                disabled = false;
                doCheck = false;
                doInstallCheck = false;
                meta = (old.meta or { }) // { broken = false; };
              });

              # WORKAROUND (2026-04-28): httpx-auth tests use 6-byte HMAC keys in
              # tests/oauth2/implicit/* fixtures. On Python 3.14, the bundled pyjwt
              # raises `jwt.warnings.InsecureKeyLengthWarning` (HMAC key < 32 bytes),
              # and the test suite's filterwarnings config promotes it to an error,
              # so all ~30 OAuth2 implicit-flow tests fail. Runtime behavior is
              # unaffected — only the test fixtures are short.
              # Affects: home-assistant (transitive dep)
              # Upstream: https://github.com/Colin-b/httpx_auth (fixtures need longer keys)
              # Check: When httpx-auth > 0.23.1 fixes the test fixtures or pyjwt
              # downgrades the warning back to a soft warning on 3.14.
              httpx-auth = pyPrev.httpx-auth.overridePythonAttrs (_old: {
                doCheck = false;
                doInstallCheck = false;
              });

              # WORKAROUND (2026-03-02): ics 0.7.2 test_gehol hits RecursionError
              # tests/test.py::TestFunctional::test_gehol exceeds max recursion depth
              # Affects: home-assistant (depends on ics for calendar integrations)
              # Upstream: https://github.com/ics-py/ics-py/issues
              # Check: When ics > 0.7.2 or upstream fixes the gehol test
              ics = pyPrev.ics.overridePythonAttrs (old: {
                disabledTests = (old.disabledTests or [ ]) ++ [
                  "test_gehol"
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
    # WORKAROUND (2026-02-12): inetutils 2.7 fails to build on Darwin
    # gnulib openat-die.c triggers -Werror,-Wformat-security on newer clang
    # Affects: home-manager (depends on inetutils for hostname)
    # Upstream: https://github.com/NixOS/nixpkgs/issues/ (gnulib compat)
    # Check: When inetutils > 2.7 or nixpkgs patches gnulib
    inetutils = prev.inetutils.overrideAttrs (old: prev.lib.optionalAttrs final.stdenv.isDarwin {
      env = (old.env or { }) // {
        NIX_CFLAGS_COMPILE = toString ((old.env.NIX_CFLAGS_COMPILE or "") + " -Wno-error=format-security");
      };
    });

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

    # Shared with unstable channel - see top of file.
    ctranslate2 = ctranslate2Override prev;

    pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
      # Shared overrides applied to both channels (see top of file).
      sharedPythonOverrides
    ];
  };
}
