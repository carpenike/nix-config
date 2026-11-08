{ inputs }:
let
  inherit (inputs.nixpkgs) lib;
  forge = inputs.self.nixosConfigurations.forge;
  c = forge.config;
  containers = c.virtualisation.oci-containers.containers;
  beszel = c.modules.services.beszel.hub;
  tracearr = c.modules.services.tracearr;
  embedded = (forge.extendModules {
    modules = [{
      modules.services.tracearr.deploymentMode = lib.mkForce "embedded";
    }];
  }).config.virtualisation.oci-containers.containers.tracearr;
  # Only unit generation is evaluated; this legacy package is not built.
  legacyBeszel = (forge.extendModules {
    modules = [{
      modules.services.beszel.hub.package = lib.mkForce
        (beszel.package.overrideAttrs (_: {
          version = "0.19.0";
          __intentionallyOverridingVersion = true;
        }));
    }];
  }).config;
  checks = {
    teslamate-probe-uses-an-installed-interpreter =
      builtins.elem "--health-cmd=bash -c 'exec 3<>/dev/tcp/127.0.0.1/4000'"
        containers.teslamate.extraOptions
      && !lib.any (lib.hasInfix "--health-cmd=nc ") containers.teslamate.extraOptions;
    beszel-keeps-schema-migration =
      c.systemd.services.beszel-hub.serviceConfig.ExecStartPre
      == [ "${beszel.package}/bin/beszel-hub migrate up" ];
    beszel-preserves-legacy-startup =
      legacyBeszel.systemd.services.beszel-hub.serviceConfig.ExecStartPre == [
        "${legacyBeszel.modules.services.beszel.hub.package}/bin/beszel-hub migrate up"
        "${legacyBeszel.modules.services.beszel.hub.package}/bin/beszel-hub history-sync"
      ];
    beszel-preserves-private-state =
      !c.systemd.services.beszel-hub.serviceConfig.DynamicUser
      && c.systemd.services.beszel-hub.serviceConfig.User == beszel.user
      && c.systemd.services.beszel-hub.serviceConfig.StateDirectoryMode == "0750";
    tracearr-external-identity =
      builtins.elem "--user=${toString tracearr.uid}:${toString tracearr.gid}"
        containers.tracearr.extraOptions;
    tracearr-embedded-identity-unchanged =
      embedded.user == null
      && !lib.any (lib.hasPrefix "--user=") embedded.extraOptions;
    tracearr-backups-use-writable-state =
      containers.tracearr.environment.BACKUP_DIR == "/data/tracearr/backup"
      && builtins.elem "${tracearr.dataDir}/tracearr:/data/tracearr:rw" containers.tracearr.volumes
      && !(embedded.environment ? BACKUP_DIR);
    tracearr-migration-lock-capacity =
      c.services.postgresql.settings.max_locks_per_transaction >= 512;
    # The four signal-* checks (container identity, no obsolete identity
    # environment, private state and loopback-only port) were removed on
    # 2026-11-08: signal-api runs on the k8s cluster (carpenike/k8s-gitops#5765)
    # and Forge has no signal-api container left to check. Its retained
    # dataset keeps mode 0700 (hosts/forge/services/retired-to-cluster.nix).
    retired-signal-api-state-stays-private =
      !(containers ? signal-api)
      && c.modules.storage.datasets.services.signal-api.mode == "0700";
  };
  failed = builtins.attrNames (lib.filterAttrs (_: passed: !passed) checks);
in
assert lib.assertMsg (failed == [ ])
  "Service startup compatibility regressions: ${lib.concatStringsSep ", " failed}";
checks
