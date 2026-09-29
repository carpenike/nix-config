{ inputs }:
let
  inherit (inputs.nixpkgs) lib;
  forge = inputs.self.nixosConfigurations.forge;
  c = forge.config;
  containers = c.virtualisation.oci-containers.containers;
  beszel = c.modules.services.beszel.hub;
  tracearr = c.modules.services.tracearr;
  signal = c.modules.services.signal-api;
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
  alternateSignal = (forge.extendModules {
    modules = [{
      modules.services.signal-api = {
        uid = signal.uid + 10000;
        gid = signal.gid + 10000;
      };
    }];
  }).config;
  checks = {
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
    signal-runtime-matches-service-identity =
      builtins.elem "--user=${toString signal.uid}:${toString signal.gid}"
        containers.signal-api.extraOptions
      && c.users.users.signal-api.uid == signal.uid
      && c.users.groups.${signal.group}.gid == signal.gid;
    signal-custom-identity-remains-supported =
      builtins.elem "--user=${toString (signal.uid + 10000)}:${toString (signal.gid + 10000)}"
        alternateSignal.virtualisation.oci-containers.containers.signal-api.extraOptions
      && alternateSignal.users.users.signal-api.uid == signal.uid + 10000
      && alternateSignal.users.groups.${signal.group}.gid == signal.gid + 10000;
    signal-no-obsolete-identity-environment =
      lib.all (name: !(builtins.hasAttr name containers.signal-api.environment))
        [ "SIGNAL_CLI_UID" "SIGNAL_CLI_GID" "PUID" "PGID" ];
    signal-preserves-private-state-and-network =
      c.modules.storage.datasets.services.signal-api.mode == "0700"
      && containers.signal-api.ports == [ "127.0.0.1:${toString signal.port}:8080" ]
      && signal.localAccess.enable;
  };
  failed = builtins.attrNames (lib.filterAttrs (_: passed: !passed) checks);
in
assert lib.assertMsg (failed == [ ])
  "Service startup compatibility regressions: ${lib.concatStringsSep ", " failed}";
checks
