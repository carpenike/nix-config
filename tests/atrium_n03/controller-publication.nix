{ pkgs, atrium, hostPkgs ? pkgs }:
let
  inherit (pkgs) lib;
  ids = import ../../lib/service-uids.nix { };
  projection = import ../../hosts/forge/atrium/credential-projection.nix { inherit lib; };
  packages = atrium.packages.${pkgs.stdenv.hostPlatform.system};
  python = pkgs.python312.withPackages (ps: [
    (ps.toPythonModule packages.resolver)
    (ps.toPythonModule packages.atrium-litellm-controller)
    (ps.toPythonModule packages.atrium-litellm-admission)
  ]);
  fixture = atrium.lib.renderForGateway {
    registry = atrium.lib.isolatedTestRegistry;
    nativeVersion = "v1.100.1";
  };
  root = "/run/atrium-controller-publication";
  installation = "controller-publication-fixture";
  issuer = "http://127.0.0.1:9";
  metadataGroup = ids.atrium-model-metadata.gid;
  desired = pkgs.writeText "publication-desired.json" (builtins.toJSON fixture.litellm);
  policy = pkgs.writeText "publication-policy.json" (builtins.toJSON fixture.resolver);
  bootstrap = "${python}/bin/python -I -B ${../../hosts/forge/atrium/model-bootstrap.py}";
  controllerConfig = unit: pkgs.writeText "${unit}-publication.json" (builtins.toJSON {
    schema_version = 1;
    environment = "isolated";
    inherit installation issuer;
    endpoint = issuer;
    desired_state = toString desired;
    ownership_directory = "${root}/controller";
    association_snapshot = "${root}/resolver-public/associations.json";
    association_publisher_uid = ids.atrium-resolver.uid;
    management_key_file = projection.path unit "management";
    backend_transports = { };
    service_delivery = { };
    service_association_snapshot = "${root}/controller-public/service-associations.json";
    bindings_snapshot = "${root}/controller-public/native-bindings.json";
    publication_reader_gid = metadataGroup;
  });
  resolverConfig = pkgs.writeText "publication-resolver.json" (builtins.toJSON {
    authorities = lib.mapAttrsToList
      (id: value: {
        inherit id;
        inherit (value) issuer audience jwks_uri;
      })
      fixture.resolver.authorities;
    isolated_harness = true;
    state_directory = "${root}/resolver/state";
    policy_path = toString policy;
    litellm = {
      endpoint = issuer;
      native_version = "v1.100.1";
      inherit installation;
      runtime_directory = "${root}/resolver/models";
      controller_key_file = projection.path "atrium-model-resolver-initialize" "model-management";
      controller_inventory_file = "${root}/controller-public/native-bindings.json";
      controller_desired_state_path = toString desired;
      controller_publisher_uid = ids.atrium-reconciler.uid;
      publication_directory = "${root}/resolver-public";
      publication_reader_gid = metadataGroup;
    };
  });
  admissionConfig = pkgs.writeText "publication-admission.json" (builtins.toJSON {
    schema_version = 1;
    isolated = true;
    native_version = "v1.100.1";
    inherit installation issuer;
    runtime_directory = "${root}/gateway/admission";
    policy_path = toString policy;
    policy_publisher_uid = 0;
    producers = [
      {
        id = "resolver";
        kind = "resolver";
        path = "${root}/resolver-public/admission-associations.json";
        publisher_uid = ids.atrium-resolver.uid;
      }
      {
        id = "controller-services";
        kind = "controller-service";
        path = "${root}/controller-public/service-associations.json";
        publisher_uid = ids.atrium-reconciler.uid;
      }
    ];
    deny_issuer = "https://resolver.atrium.invalid";
    deny_url = "${issuer}/feed";
    jwks_url = "${issuer}/jwks";
    fetch_timeout_seconds = 1;
  });
  program = pkgs.writeText "controller-publication-fixture.py" ''
    import hashlib
    import json
    import os
    import secrets
    import socket
    import stat
    import subprocess
    import sys
    import time
    from pathlib import Path

    ROOT = Path("${root}")
    CONFIG = Path("${controllerConfig "atrium-reconciler"}")
    INITIAL_CONFIG = Path("${controllerConfig "atrium-model-controller-initialize"}")
    BOOTSTRAP = "${../../hosts/forge/atrium/model-bootstrap.py}"
    PUBLICATION = ROOT / "controller-public/service-associations.json"
    INSTALLATION = "${installation}"
    ISSUER = "${issuer}"

    def write(path, body, mode=0o600):
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode)
        with os.fdopen(descriptor, "wb") as stream:
            os.fchmod(stream.fileno(), mode)
            stream.write(body)

    def receipt(name, data):
        from atrium_litellm.files import atomic_json

        atomic_json(ROOT / name, data)

    def network_blocked():
        interfaces = Path("/proc/net/dev").read_text().splitlines()[2:]
        assert {line.split(":")[0].strip() for line in interfaces} == {"lo"}
        for family in (socket.AF_INET, socket.AF_INET6):
            try:
                connection = socket.socket(family, socket.SOCK_STREAM)
            except OSError:
                continue
            connection.close()
            raise AssertionError("fixture permitted an IP socket")

    def setup():
        for name, uid, gid, mode in (
            ("secrets", 0, 0, 0o700),
            ("resolver", ${toString ids.atrium-resolver.uid}, ${toString ids.atrium-resolver.gid}, 0o700),
            ("controller", ${toString ids.atrium-reconciler.uid}, ${toString ids.atrium-reconciler.gid}, 0o700),
            ("cases", ${toString ids.atrium-reconciler.uid}, ${toString ids.atrium-reconciler.gid}, 0o700),
            ("gateway", ${toString ids.atrium-model-gateway.uid}, ${toString ids.atrium-model-gateway.gid}, 0o700),
            ("resolver-public", ${toString ids.atrium-resolver.uid}, ${toString metadataGroup}, 0o2750),
            ("controller-public", ${toString ids.atrium-reconciler.uid}, ${toString metadataGroup}, 0o2750),
        ):
            path = ROOT / name
            path.mkdir(mode=mode)
            os.chown(path, uid, gid)
            path.chmod(mode)
            assert stat.S_IMODE(path.stat().st_mode) == mode
        for name in ("management", "model-management", "personal-anthropic", "family-anthropic"):
            raw = ("sk-" + secrets.token_urlsafe(32)).encode()
            write(ROOT / "secrets" / name, raw)
            if name == "management":
                write(ROOT / "management-hash", hashlib.sha256(raw).hexdigest().encode(), 0o644)

    def resolver():
        from atrium_resolver.config import load_settings
        from atrium_resolver.litellm_broker import LiteLLMBroker
        from atrium_resolver.policy import PolicyEngine
        from atrium_resolver.state import State

        settings = load_settings(Path("${resolverConfig}"))
        assert (settings.litellm.runtime_directory / "initialized").read_text().strip() == INSTALLATION
        state = State(settings.state_directory)
        try:
            broker = LiteLLMBroker(PolicyEngine(settings, state), settings.litellm)
            broker.close()
        finally:
            state.close()

    def controller(config_path=CONFIG):
        from atrium_litellm.associations import ProtectedSnapshotSource
        from atrium_litellm.controller import Controller
        from atrium_litellm.desired import Desired
        from atrium_litellm.files import read_bytes
        from atrium_litellm.ledger import Ledger
        from atrium_litellm.native import Native

        config = json.loads(config_path.read_bytes())
        desired = Desired.read(Path(config["desired_state"]))
        ledger = Ledger(Path(config["ownership_directory"]), INSTALLATION, ISSUER)
        control = read_bytes(Path(config["management_key_file"]), secret=True).decode()
        assert hashlib.sha256(control.encode()).hexdigest() == (ROOT / "management-hash").read_text()
        return Controller(
            desired, ledger, Native(ISSUER, control),
            ProtectedSnapshotSource(
                Path(config["association_snapshot"]), INSTALLATION, ISSUER,
                config["association_publisher_uid"],
            ),
            config["backend_transports"],
            service_delivery=config["service_delivery"],
            service_association_snapshot=Path(config["service_association_snapshot"]),
            bindings_snapshot=Path(config["bindings_snapshot"]),
            publication_reader_gid=config["publication_reader_gid"],
        )

    def seed():
        from atrium_litellm.files import atomic_json

        current = controller(INITIAL_CONFIG)
        ledger = current.ledger
        now = int(time.time())
        template = current.desired.templates["whiskey-service"]
        retained = ROOT / "controller/retained"
        retained.mkdir(mode=0o700)
        with ledger.locked():
            assert ledger.state["revision"] == 1 and ledger.state["keys"] == {}
            ledger.remember(current.associations.read(now))
            ledger.state["teams"][template["team"]] = {
                "native_id": "retained-synthetic-team",
                "status": "owned", "provenance": "controller-created",
            }
            for name in ("active", "expired", "revoked", "retired"):
                raw = ("sk-" + secrets.token_urlsafe(32)).encode()
                write(retained / name, raw)
                digest = hashlib.sha256(raw).hexdigest()
                ledger.state["keys"][digest] = {
                    "source": "controller",
                    "retired": name == "retired",
                    "association": {
                        "issuer": ISSUER, "credential_id": digest, "native_key_id": digest,
                        "principal_id": template["service"]["principal"],
                        "authority_id": "controller", "domain": template["domain"],
                        "template_id": "whiskey-service", "native_team_id": "retained-synthetic-team",
                        "issued_at": now - 700,
                        "expires_at": now - 100 if name == "expired" else now + 1800,
                        "device_id": None, "state": "revoked" if name == "revoked" else "active",
                        "effective_limits": {
                            field: template[field] for field in ("models", "routes", "budget")
                        },
                    },
                }
            ledger.save()
            # Use the real publisher's clock argument instead of waiting 300 seconds.
            current.publish_service_associations(now - 600)
            atomic_json(ROOT / "controller/baseline.json", {
                "state": ledger.state,
                "publication": json.loads(PUBLICATION.read_bytes()),
                "lock_inode": (ledger.path / "ownership.lock").stat().st_ino,
            })

    def verify():
        current = controller()
        state = current.ledger.load()
        baseline = json.loads((ROOT / "controller/baseline.json").read_bytes())
        publication = json.loads(PUBLICATION.read_bytes())
        assert state["revision"] > baseline["state"]["revision"]
        assert {k: v for k, v in state.items() if k != "revision"} == {
            k: v for k, v in baseline["state"].items() if k != "revision"
        }
        assert (current.ledger.path / "ownership.lock").stat().st_ino == baseline["lock_inode"]
        by_key = lambda row: row["native_key_id"]
        assert sorted(publication["associations"], key=by_key) == sorted(
            baseline["publication"]["associations"], key=by_key,
        )
        assert publication["generation"] == state["revision"]
        assert publication["generated_at"] <= int(time.time()) < publication["expires_at"]
        assert publication["expires_at"] - publication["generated_at"] == 300
        assert not current.bindings_snapshot.exists()
        metadata = PUBLICATION.stat()
        assert (metadata.st_uid, metadata.st_gid, stat.S_IMODE(metadata.st_mode)) == (
            ${toString ids.atrium-reconciler.uid}, ${toString metadataGroup}, 0o640,
        )
        receipt("controller/permit.json", {
            "generation": publication["generation"], "records": len(publication["associations"]),
            "same_history": True, "exact_records": True, "native_writes": False,
        })

    def admission(mode):
        from atrium_admission.engine import Admission
        from atrium_admission.models import AdmissionError, Settings
        from atrium_admission.producers import read_producer
        from atrium_admission.state import State

        settings = Settings.model_validate_json(Path("${admissionConfig}").read_bytes())
        if mode == "initialize":
            State(settings).initialize()
            return
        app = Admission(settings, start_poller=False)
        try:
            producer = settings.producers[1]
            management_hash = (ROOT / "management-hash").read_text()
            if mode == "stale":
                try:
                    read_producer(producer, settings, app.policy(), int(time.time()))
                except AdmissionError as error:
                    assert error.code == "service_producer_stale"
                else:
                    raise AssertionError("stale service publication accepted")
                try:
                    app.admit(management_hash, None, None, "/team/info")
                except AdmissionError as error:
                    assert (error.code, error.status) == ("ownership_unverified", 503)
                else:
                    raise AssertionError("unowned management bypassed a stale producer")
                result = {"stale_producer_denied": True, "management_denied": True}
            else:
                assert mode == "permit"
                candidate = read_producer(producer, settings, app.policy(), int(time.time()))
                assert len(candidate[3]) == 4
                assert app.admit(management_hash, None, None, "/team/info") == "verified-non-owned"
                denied = 0
                for record in candidate[3]:
                    path = "/team/info" if (
                        record.status == "prepared" and record.expires_at > int(time.time())
                    ) else record.routes[0]
                    try:
                        app.admit(record.native_key_id, record.team_id, record.models[0], path)
                    except AdmissionError as error:
                        assert error.code == "owned_request_not_permitted"
                        denied += 1
                    else:
                        raise AssertionError("owned expiry, revocation or management boundary weakened")
                with app.store.transaction() as state:
                    assert len(state["history"]) == 4
                    assert state["feed"] is None and state["feed_error"] == "deny_transport_unavailable"
                result = {"management_permitted": True, "records": 4, "owned_denied": denied}
            receipt("gateway/" + mode + ".json", result)
        finally:
            app.close()

    def inventory(directories):
        return {
            str(path.relative_to(ROOT)): (
                path.stat().st_ino, path.stat().st_uid, path.stat().st_gid,
                path.stat().st_mode, path.read_bytes() if path.is_file() else None,
            )
            for directory in directories
            for path in (ROOT / directory).rglob("*")
        }

    def invoke(
        producer, config, confirmation, *, permit=False,
        directories=("controller", "controller-public", "cases"),
    ):
        before = inventory(directories)
        completed = subprocess.run(
            [sys.executable, "-I", "-B", BOOTSTRAP, producer, "--config", str(config), *confirmation],
            capture_output=True, timeout=20,
        )
        if permit:
            assert completed.returncode == 0 and completed.stderr == b""
            assert json.loads(completed.stdout) == {"published": "controller", "native_writes": False}
        else:
            code = "atrium_model_" + (
                "publication" if producer == "controller-publication" else "initialization"
            ) + "_rejected"
            assert completed.returncode != 0 and completed.stdout == b""
            assert completed.stderr.decode().strip() == code
            assert inventory(directories) == before

    def resolver_denial():
        from atrium_litellm.files import atomic_json

        path = ROOT / "resolver/wrong-mode"
        path.mkdir(mode=0o700)
        config = json.loads(Path("${resolverConfig}").read_bytes())
        config["state_directory"] = str(path / "state")
        config["litellm"]["runtime_directory"] = str(path / "models")
        candidate = path / "config.json"
        atomic_json(candidate, config)
        invoke(
            "resolver", candidate, ["--confirm-existing-installation", INSTALLATION],
            directories=("resolver", "resolver-public"),
        )
        assert not (path / "state").exists() and not (path / "models").exists()
        receipt("resolver/denials.json", {"rejected": 1, "unchanged_on_rejection": True})

    def denials():
        from atrium_litellm.files import atomic_json
        from atrium_litellm.ledger import Ledger

        config = json.loads(CONFIG.read_bytes())
        existing = ["--confirm-existing-installation", INSTALLATION]
        for fault in ("missing", "corrupt", "wrong-installation"):
            path = ROOT / "cases" / fault
            if fault != "missing":
                path.mkdir(mode=0o700)
                ledger = Ledger(path, "different-fixture" if fault == "wrong-installation" else INSTALLATION, ISSUER)
                ledger.initialize()
                if fault == "corrupt":
                    envelope = json.loads((path / "ownership.json").read_bytes())
                    envelope["state"]["revision"] += 1
                    atomic_json(path / "ownership.json", envelope)
            candidate = ROOT / "cases" / (fault + ".json")
            atomic_json(candidate, {**config, "ownership_directory": str(path)})
            invoke("controller-publication", candidate, existing)
            if fault == "missing":
                assert not path.exists()
        fresh = ROOT / "cases/wrong-mode"
        fresh.mkdir(mode=0o700)
        wrong_mode = ROOT / "cases/wrong-mode.json"
        atomic_json(wrong_mode, {**config, "ownership_directory": str(fresh)})
        for producer, candidate, confirmation in (
            ("controller-publication", CONFIG, ["--confirm-new-installation", INSTALLATION]),
            ("controller-publication", CONFIG, ["--confirm-existing-installation", "different-fixture"]),
            ("controller", wrong_mode, existing),
            ("controller", CONFIG, ["--confirm-new-installation", INSTALLATION]),
        ):
            invoke(producer, candidate, confirmation)
        candidate = ROOT / "cases/unavailable-resolver.json"
        atomic_json(candidate, {**config, "association_snapshot": str(ROOT / "missing-resolver.json")})
        before = controller().ledger.load()["revision"]
        invoke("controller-publication", candidate, existing, permit=True)
        assert controller().ledger.load()["revision"] == before + 1
        verify()
        receipt("controller/denials.json", {
            "rejected": 7, "unchanged_on_rejection": True,
            "missing_resolver_permitted": True, "native_writes": False,
        })

    def audit():
        logs = subprocess.run(
            ["journalctl", "--no-pager", "--output=cat"], capture_output=True, check=True,
        ).stdout
        documents = [path.read_bytes() for path in ROOT.rglob("*.json")]
        credentials = list((ROOT / "secrets").iterdir()) + list((ROOT / "controller/retained").iterdir())
        for path in credentials:
            raw = path.read_bytes()
            assert raw and raw not in logs and all(raw not in document for document in documents)
        print(json.dumps({"credential_values_checked": len(credentials), "credential_leaks": 0}))

    if sys.argv[1] != "audit":
        network_blocked()
    action = sys.argv[1]
    if action == "admission":
        admission(sys.argv[2])
    else:
        {"setup": setup, "resolver": resolver, "seed": seed, "verify": verify,
         "denials": denials, "resolver-denial": resolver_denial, "audit": audit}[action]()
  '';
  command = "${python}/bin/python -I -B ${program}";
  hardened = {
    Type = "oneshot";
    UMask = "0077";
    PrivateNetwork = true;
    RestrictAddressFamilies = [ "AF_UNIX" ];
    ProtectSystem = "strict";
    ProtectHome = true;
    PrivateDevices = true;
    NoNewPrivileges = true;
    CapabilityBoundingSet = [ "" ];
    LimitCORE = 0;
    MemoryMax = "256M";
    TasksMax = 64;
    TimeoutStartSec = 60;
    StandardOutput = "journal";
    StandardError = "journal";
  };
  actor = user: {
    requires = [ "atrium-publication-fixture.service" ];
    after = [ "atrium-publication-fixture.service" ];
    serviceConfig = hardened // {
      User = user;
      Group = user;
      SupplementaryGroups = [ "atrium-model-metadata" ];
      ReadWritePaths = [ root ];
    };
  };
  projected = unit: names: projection.serviceConfig
    {
      inherit pkgs unit;
      credentials = lib.genAttrs names (name: "${root}/secrets/${name}");
    } // {
    LoadCredential = map (name: "${name}:${root}/secrets/${name}") names;
    RemainAfterExit = true;
  };
  reconcilerProjection = projected "atrium-reconciler" [
    "management"
    "personal-anthropic"
    "family-anthropic"
  ];
in
hostPkgs.testers.runNixOSTest {
  name = "atrium-forge-controller-publication";
  globalTimeout = 300;
  node.pkgs = lib.mkForce pkgs;
  nodes.machine = {
    virtualisation = { memorySize = 1024; cores = 1; vlans = [ ]; };
    networking.hostName = "atrium-publication-fixture";
    networking.useDHCP = false;
    users.groups = lib.genAttrs [
      "atrium-resolver"
      "atrium-reconciler"
      "atrium-model-gateway"
      "atrium-model-metadata"
    ]
      (name: { inherit (ids.${name}) gid; });
    users.users = lib.genAttrs [
      "atrium-resolver"
      "atrium-reconciler"
      "atrium-model-gateway"
    ]
      (name: {
        isSystemUser = true;
        inherit (ids.${name}) uid;
        group = name;
        extraGroups = [ "atrium-model-metadata" ];
      });
    systemd.services = {
      atrium-publication-fixture.serviceConfig = hardened // {
        RemainAfterExit = true;
        RuntimeDirectory = "atrium-controller-publication";
        RuntimeDirectoryMode = "0755";
        CapabilityBoundingSet = [ "CAP_CHOWN" "CAP_DAC_OVERRIDE" "CAP_FOWNER" "CAP_FSETID" ];
        ExecStart = "${command} setup";
      };
      atrium-model-resolver-initialize = lib.recursiveUpdate (actor "atrium-resolver") {
        serviceConfig = projected "atrium-model-resolver-initialize" [ "model-management" ] // {
          ExecStart = "${bootstrap} resolver --config ${resolverConfig} --confirm-new-installation ${installation}";
        };
      };
      atrium-resolver = lib.recursiveUpdate (actor "atrium-resolver") {
        requires = [ "atrium-model-resolver-initialize.service" ];
        after = [ "atrium-model-resolver-initialize.service" ];
        serviceConfig = {
          RemainAfterExit = true;
          ExecStart = "${command} resolver";
        };
      };
      atrium-model-controller-initialize = lib.recursiveUpdate (actor "atrium-reconciler") {
        requires = [ "atrium-resolver.service" ];
        after = [ "atrium-resolver.service" ];
        serviceConfig = projected "atrium-model-controller-initialize" [ "management" ] // {
          ExecStart = "${bootstrap} controller --config ${controllerConfig "atrium-model-controller-initialize"} --confirm-new-installation ${installation}";
          ExecStartPost = "${command} seed";
        };
      };
      atrium-reconciler = lib.recursiveUpdate (actor "atrium-reconciler") {
        requires = [ "atrium-resolver.service" ];
        after = [ "atrium-resolver.service" ];
        serviceConfig = reconcilerProjection // {
          ExecStartPre = reconcilerProjection.ExecStartPre ++ [
            "${bootstrap} controller-publication --config ${controllerConfig "atrium-reconciler"} --confirm-existing-installation ${installation}"
          ];
          ExecStart = "${command} verify";
        };
      };
      "atrium-publication-admission@" = lib.recursiveUpdate (actor "atrium-model-gateway") {
        serviceConfig.ExecStart = "${command} admission %i";
      };
      atrium-publication-denials = lib.recursiveUpdate (actor "atrium-reconciler") {
        serviceConfig.ExecStart = "${command} denials";
      };
      atrium-publication-resolver-denial = lib.recursiveUpdate (actor "atrium-resolver") {
        serviceConfig.ExecStart = "${command} resolver-denial";
      };
    };
    system.stateVersion = "25.11";
  };
  testScript = ''
    import json

    machine.start()
    machine.wait_for_unit("multi-user.target")
    machine.succeed("systemctl start atrium-model-controller-initialize")
    machine.succeed("systemctl start atrium-publication-admission@initialize")
    machine.succeed("systemctl start atrium-publication-admission@stale")
    stale = json.loads(machine.succeed("cat ${root}/gateway/stale.json"))
    assert stale == {"stale_producer_denied": True, "management_denied": True}

    generations = []
    for attempt in range(2):
        machine.succeed("systemctl start atrium-reconciler")
        publication = json.loads(machine.succeed("cat ${root}/controller/permit.json"))
        assert publication["same_history"] and publication["exact_records"]
        assert publication["records"] == 4 and not publication["native_writes"]
        generations.append(publication["generation"])
        machine.succeed("systemctl start atrium-publication-admission@permit")
        permit = json.loads(machine.succeed("cat ${root}/gateway/permit.json"))
        assert permit == {"management_permitted": True, "records": 4, "owned_denied": 4}
        if attempt == 0:
            machine.succeed("systemctl stop atrium-reconciler")
            machine.succeed("test ! -e /run/atrium-reconciler-credentials")
    assert generations[1] == generations[0] + 1
    machine.succeed("systemctl start atrium-publication-denials")
    denials = json.loads(machine.succeed("cat ${root}/controller/denials.json"))
    assert denials == {
        "rejected": 7, "unchanged_on_rejection": True,
        "missing_resolver_permitted": True, "native_writes": False,
    }
    machine.succeed("systemctl start atrium-publication-resolver-denial")
    resolver_denial = json.loads(machine.succeed("cat ${root}/resolver/denials.json"))
    assert resolver_denial == {"rejected": 1, "unchanged_on_rejection": True}
    machine.succeed("systemctl start atrium-publication-admission@permit")
    audit = json.loads(machine.succeed("${command} audit"))
    assert audit == {"credential_values_checked": 8, "credential_leaks": 0}
    machine.succeed(
        "systemctl stop atrium-reconciler atrium-model-controller-initialize "
        "atrium-resolver atrium-model-resolver-initialize atrium-publication-fixture"
    )
    machine.succeed(
        "test ! -e ${root}; test ! -e /run/atrium-reconciler-credentials; "
        "test ! -e /run/atrium-model-controller-initialize-credentials; "
        "test ! -e /run/atrium-model-resolver-initialize-credentials"
    )
    print(json.dumps({
        "kind": "atrium.controller-publication-startup",
        "stale_denials": 2, "publication_permits": 3, "management_permits": 3,
        "retained_records": 4, "bootstrap_denials": 8, "owned_denials": 12,
        "same_initialized_history": True, "ip_sockets_forbidden": True,
        "real_LoadCredential_projection": True, "cleanup": True,
        "credential_leaks": 0, "native_writes": False, "live_operations": False,
        "source_sha256": {
            "bootstrap": "${builtins.hashFile "sha256" ../../hosts/forge/atrium/model-bootstrap.py}",
            "test": "${builtins.hashFile "sha256" ./controller-publication.nix}",
        },
        "atrium_revision": "${atrium.rev}",
    }, sort_keys=True))
  '';
}
