# On-demand upgrade module for NixOS hosts
#
# The privileged half of "apply the latest committed config, now". It pairs
# with modules/nixos/auto-upgrade.nix: that module owns the nightly timer and
# the nixos-upgrade.service definition (flake URL, memory limits, exit-code-4
# tolerance, Pushover + Prometheus reporting); this one just starts that same
# unit when something asks.
#
# The asker is an unprivileged service — homelab-mcp, which exposes the
# nixos_apply_config MCP tool so a Claude session or a phone can trigger a
# deploy. It cannot start a root unit and must not be able to: it runs with
# NoNewPrivileges and an empty capability set. So the request crosses the
# privilege boundary as a FILE:
#
#   homelab-mcp writes  /run/nixos-deploy-trigger/requests/<id>.json
#     -> systemd.paths watches that directory (DirectoryNotEmpty)
#     -> this unit (root) consumes the files and starts nixos-upgrade.service
#     -> it writes  /run/nixos-deploy-trigger/status.json  for the poll
#
# The security property is that the payload is inert. The file's EXISTENCE is
# the entire signal; its JSON body is copied into the status file as data (via
# jq --arg, bounded) and is never parsed as arguments. Nothing a requester
# writes selects a flake, a branch, a host, or a nixos-rebuild flag — those
# live here. The worst a compromised or prompt-injected requester achieves is
# applying already-merged main at an awkward moment, which is what the nightly
# timer does unattended anyway.
#
# Deliberately NOT taken: the deployment-guard lease that
# scripts/nix-apply-guarded.sh holds around laptop-driven deploys. This path
# has the same posture as the nightly run — a plain switch, no backup-timer
# quiescing. Same risk, already accepted daily.
#
# Usage:
#   modules.onDemandUpgrade = {
#     enable = true;
#     requestUser = "homelab-mcp";
#   };
{ config, lib, pkgs, ... }:

let
  cfg = config.modules.onDemandUpgrade;

  triggerScript = pkgs.writeShellScript "nixos-on-demand-upgrade" ''
    set -uo pipefail

    requests=${lib.escapeShellArg cfg.requestDir}
    status=${lib.escapeShellArg cfg.statusPath}
    unit=${lib.escapeShellArg cfg.unit}
    min_interval=${toString cfg.minIntervalSeconds}

    # Every field is passed to jq as a bound argument, never interpolated
    # into a program. Requester-supplied text reaches this file as a JSON
    # string value and nowhere else.
    write_status() {
      local tmp
      tmp="$(${pkgs.coreutils}/bin/mktemp "$status.XXXXXX")"
      ${pkgs.jq}/bin/jq -n \
        --arg state "$1" \
        --arg detail "$2" \
        --arg reason "''${reason:-}" \
        --arg requested_at "''${requested_at:-}" \
        --arg started_at "''${started_at:-}" \
        --arg finished_at "$(${pkgs.coreutils}/bin/date -Iseconds)" \
        --argjson finished_at_epoch "$(${pkgs.coreutils}/bin/date +%s)" \
        --argjson requests "''${consumed:-0}" \
        --argjson duration_seconds "''${duration:-0}" \
        --arg old_system "''${old_system:-}" \
        --arg new_system "''${new_system:-}" \
        --argjson reboot_required "''${reboot_required:-false}" \
        '{
           state: $state,
           detail: $detail,
           reason: $reason,
           requested_at: $requested_at,
           started_at: $started_at,
           finished_at: $finished_at,
           finished_at_epoch: $finished_at_epoch,
           collapsed_requests: $requests,
           duration_seconds: $duration_seconds,
           old_system: $old_system,
           new_system: $new_system,
           reboot_required: $reboot_required
         }' > "$tmp"
      ${pkgs.coreutils}/bin/chmod 0644 "$tmp"
      ${pkgs.coreutils}/bin/mv -f "$tmp" "$status"
    }

    ${pkgs.coreutils}/bin/mkdir -p "$(${pkgs.coreutils}/bin/dirname "$status")"

    shopt -s nullglob
    files=("$requests"/*)
    consumed=''${#files[@]}
    if (( consumed == 0 )); then
      # Spurious activation (the watcher can re-arm after the last file is
      # consumed). Nothing to do, and nothing worth overwriting status with.
      exit 0
    fi

    # A burst collapses into one deploy: the newest request supplies the
    # human-facing fields, and every file is consumed so the watcher settles.
    newest="''${files[0]}"
    for f in "''${files[@]}"; do
      [[ "$f" -nt "$newest" ]] && newest="$f"
    done
    reason="$(${pkgs.jq}/bin/jq -r 'if type == "object" and (.reason | type) == "string"
                                    then .reason[0:200] else "" end' \
      "$newest" 2>/dev/null || echo "")"
    requested_at="$(${pkgs.jq}/bin/jq -r 'if type == "object" and (.requested_at | type) == "string"
                                          then .requested_at[0:64] else "" end' \
      "$newest" 2>/dev/null || echo "")"
    ${pkgs.coreutils}/bin/rm -f -- "''${files[@]}"

    echo "on-demand upgrade requested (collapsed $consumed request(s)): ''${reason:-no reason given}"

    if ${pkgs.systemd}/bin/systemctl is-active --quiet "$unit"; then
      write_status rejected "$unit is already running; this request was dropped rather than queued."
      exit 0
    fi

    # Cheap anti-flap guard at the privileged layer, so a requester stuck in
    # a retry loop cannot switch the host continuously. Rejections are
    # recorded rather than silent — the poll has to be able to explain them.
    last_finished="$(${pkgs.jq}/bin/jq -r '.finished_at_epoch // 0' "$status" 2>/dev/null || echo 0)"
    [[ "$last_finished" =~ ^[0-9]+$ ]] || last_finished=0
    now="$(${pkgs.coreutils}/bin/date +%s)"
    if (( min_interval > 0 && last_finished > 0 && now - last_finished < min_interval )); then
      write_status rejected \
        "Another deploy finished $(( now - last_finished ))s ago; minimum interval is ''${min_interval}s."
      exit 0
    fi

    old_system="$(${pkgs.coreutils}/bin/readlink -f /run/current-system 2>/dev/null || echo "")"
    started_at="$(${pkgs.coreutils}/bin/date -Iseconds)"
    start_epoch="$now"
    write_status running "Rebuilding and switching to the latest committed configuration."

    # Blocks until the job completes. nixos-upgrade.service already treats
    # exit code 4 (config applied, transient units failed) as success via
    # SuccessExitStatus, so that verdict is inherited here rather than
    # re-derived.
    if ${pkgs.systemd}/bin/systemctl start "$unit"; then
      result=succeeded
      detail="Configuration applied."
    else
      result=failed
      detail="$unit failed; see journalctl -u $unit."
    fi

    duration=$(( $(${pkgs.coreutils}/bin/date +%s) - start_epoch ))
    new_system="$(${pkgs.coreutils}/bin/readlink -f /run/current-system 2>/dev/null || echo "")"

    # A reboot is needed when the running kernel/initrd/systemd no longer
    # match the deployed ones — the same triple nixos-rebuild compares.
    reboot_required=false
    for link in kernel initrd systemd; do
      booted="$(${pkgs.coreutils}/bin/readlink -f "/run/booted-system/$link" 2>/dev/null || echo "")"
      current="$(${pkgs.coreutils}/bin/readlink -f "/run/current-system/$link" 2>/dev/null || echo "")"
      if [[ -n "$booted" && -n "$current" && "$booted" != "$current" ]]; then
        reboot_required=true
        break
      fi
    done

    # Only meaningful when the switch actually ran: a FAILED deploy also
    # leaves the system path unchanged, and reporting that as "already up to
    # date" would turn a failure into reassurance.
    if [[ "$result" == succeeded && "$old_system" == "$new_system" ]]; then
      detail="$detail No change: the host was already on the latest committed configuration."
    fi

    write_status "$result" "$detail"
    [[ "$result" == succeeded ]]
  '';
in
{
  options.modules.onDemandUpgrade = {
    enable = lib.mkEnableOption ''
      on-demand triggering of nixos-upgrade.service by an unprivileged
      requester.

      Requires modules.autoUpgrade, which defines the unit this starts and
      pins the flake URL that is deployed
    '';

    requestUser = lib.mkOption {
      type = lib.types.str;
      example = "homelab-mcp";
      description = ''
        Service user allowed to request deploys. It gets ownership of
        `requestDir` (mode 0700) and nothing else — no sudo rule, no polkit
        exemption, no D-Bus access. Its whole capability is "create a file
        in one directory".
      '';
    };

    requestGroup = lib.mkOption {
      type = lib.types.str;
      default = cfg.requestUser;
      defaultText = lib.literalExpression "config.modules.onDemandUpgrade.requestUser";
      description = "Group owning `requestDir`. Defaults to the requester's own group.";
    };

    requestDir = lib.mkOption {
      type = lib.types.str;
      default = "/run/nixos-deploy-trigger/requests";
      description = ''
        Watched drop directory. Anything that appears here triggers a
        deploy, so it must hold nothing else — do not point this at a
        general-purpose runtime directory.
      '';
    };

    statusPath = lib.mkOption {
      type = lib.types.str;
      default = "/run/nixos-deploy-trigger/status.json";
      description = ''
        World-readable JSON status the requester polls. Written by root
        outside `requestDir` so the subject of the report cannot edit it.
      '';
    };

    unit = lib.mkOption {
      type = lib.types.str;
      default = "nixos-upgrade.service";
      description = ''
        The unit started on request. Deliberately the same one the nightly
        timer runs: a second deploy path with its own flags would be a
        second thing to keep correct.
      '';
    };

    minIntervalSeconds = lib.mkOption {
      type = lib.types.int;
      default = 120;
      description = ''
        Minimum gap between accepted requests. Anti-flap only — a requester
        in a retry loop should not switch the host continuously. Rejected
        requests are recorded in `statusPath` with a reason rather than
        dropped silently. Set to 0 to disable.
      '';
    };

    timeout = lib.mkOption {
      type = lib.types.str;
      default = "3h";
      description = ''
        TimeoutStartSec for the trigger unit. It waits on a full rebuild, so
        this must exceed the longest plausible build; the default 90s would
        abandon the wait (and lose the status write) minutes in. Timing out
        here does not stop the rebuild itself.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.modules.autoUpgrade.enable;
        message =
          "modules.onDemandUpgrade requires modules.autoUpgrade: it starts "
          + "that module's ${cfg.unit}, which otherwise does not exist.";
      }
      {
        assertion = !(lib.hasPrefix "${cfg.requestDir}/" cfg.statusPath);
        message =
          "modules.onDemandUpgrade.statusPath must live outside requestDir, "
          + "which is writable by ${cfg.requestUser}.";
      }
    ];

    # /run is a tmpfs, so these are recreated on every boot with no stale
    # requests carried across — a reboot cannot replay a deploy.
    systemd.tmpfiles.rules = [
      "d ${builtins.dirOf cfg.statusPath} 0755 root root -"
      "d ${cfg.requestDir} 0700 ${cfg.requestUser} ${cfg.requestGroup} -"
    ];

    systemd.paths.nixos-on-demand-upgrade = {
      description = "Watch for on-demand NixOS upgrade requests";
      wantedBy = [ "multi-user.target" ];
      pathConfig = {
        # DirectoryNotEmpty rather than PathExists: the trigger consumes
        # every pending file, so a request arriving mid-deploy still
        # re-arms the watcher instead of being lost.
        DirectoryNotEmpty = cfg.requestDir;
        MakeDirectory = false;
      };
    };

    systemd.services.nixos-on-demand-upgrade = {
      description = "Apply the latest committed NixOS configuration on request";

      # Started only by the path unit above.
      wantedBy = [ ];

      # The switch this unit is waiting on may change this unit's own
      # definition. Without these, switch-to-configuration would restart it
      # mid-deploy, killing the `systemctl start` it is blocked on and
      # losing the status write that the requester is polling for.
      restartIfChanged = false;
      stopIfChanged = false;

      serviceConfig = {
        Type = "oneshot";
        ExecStart = triggerScript;
        TimeoutStartSec = cfg.timeout;
        # Runs as root deliberately and unsandboxed: its entire job is to
        # start a unit that rebuilds the system. The boundary is upstream —
        # only the request user can write to the watched directory, and
        # nothing in what it writes reaches a command line.
        #
        # No onFailure handler: a failed deploy IS a failed
        # nixos-upgrade.service, which already sends the Pushover
        # notification and records the Prometheus failure metric (see
        # auto-upgrade.nix). A second alert for the same event would just
        # train us to ignore both.
      };
    };
  };
}
