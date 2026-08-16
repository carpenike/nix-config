{ lib, config, ... }:
let
  # NixOS appends ".service" when rendering each `systemd.services.<name>`
  # attribute, so a key that already carries the suffix produces a unit file
  # named `<name>.service.service`. That unit has no ExecStart, is referenced
  # by nothing, and never loads — every setting attached to it vanishes with
  # no error. Catch the typo at eval time instead of discovering it in prod.
  phantomServiceUnits =
    builtins.filter (lib.hasSuffix ".service") (builtins.attrNames config.systemd.services);
in
{
  # Disable automatic generation of /etc/machine-id to allow impermanence to manage it
  systemd.services."systemd-machine-id-setup" = {
    enable = false; # Prevent NixOS from overwriting /etc/machine-id
  };

  assertions = [
    {
      assertion = phantomServiceUnits == [ ];
      message = ''
        systemd.services attribute keys must not end in ".service" — NixOS
        appends the suffix itself, so these keys render as phantom
        "<name>.service.service" units that never load, silently discarding
        everything defined under them:

        ${lib.concatMapStringsSep "\n" (n: "  - systemd.services.\"${n}\"") phantomServiceUnits}

        Drop the ".service" suffix from the attribute key. If the same string
        is also needed as a unit *name* for cross-references (after, requires,
        OnFailure, partOf), keep two bindings — an unsuffixed one for the key
        and a suffixed one for the references.
      '';
    }
  ];
}
