# Delivery of queued notification payloads.
#
# The dispatcher (default.nix) writes /run/notify/<template>:<instance>.json and
# does not start any backend itself, to avoid permission problems with
# DynamicUser. Something else has to notice the file.
#
# That used to be a per-instance systemd .path unit, one per notification. It
# could never work: the instance is chosen by the caller at failure time
# (notify@<template>:%n), so the set of instance names does not exist until a
# unit actually fails, and therefore cannot be enumerated at build time. Only 3
# instances were ever declared against 34 registration sites, so payloads
# accumulated unread in /run/notify for over a month while every dispatch
# reported Result=success.
#
# One directory watcher removes the whole bug class: no per-caller
# registration, dynamic instances work by construction, and there is nothing
# left to forget to declare.
{ lib
, config
, pkgs
, ...
}:
let
  cfg = config.modules.notifications;
  backlogCfg = cfg.backlogAlarm;

  funcName = name: "deliver_" + lib.replaceStrings [ "-" ] [ "_" ] name;

  # Each backend contributes a shell function. Delivery is invoked in a
  # subshell so that a backend calling `exit` or flipping `set -e` cannot take
  # the drain down with it and strand the rest of the queue.
  deliverFunctions = lib.concatStringsSep "\n" (
    lib.mapAttrsToList
      (name: backend: ''
        ${funcName name}() {
        ${backend.deliver}
        }
      '')
      cfg.backends
  );

  deliverDispatch = ''
    # Deliver one notification. Reads TITLE, MESSAGE and PRIORITY from the
    # environment; returns non-zero if it did not actually go out.
    deliver_to() {
      case "$1" in
    ${lib.concatStringsSep "\n" (
      lib.mapAttrsToList (name: _: ''    ${name}) ( ${funcName name} ) ;;'') cfg.backends
    )}
        all)
          _rc=0
    ${lib.concatStringsSep "\n" (
      lib.mapAttrsToList (name: _: ''      ( ${funcName name} ) || _rc=1'') cfg.backends
    )}
          return "$_rc"
          ;;
        *)
          echo "[notify] ERROR: no enabled backend named '$1'" >&2
          return 1
          ;;
      esac
    }
  '';

  allCredentials = lib.unique (
    lib.concatLists (lib.mapAttrsToList (_: b: b.credentials) cfg.backends)
  );

  # Common serviceConfig for units that deliver notifications directly.
  deliveryServiceConfig = {
    Type = "oneshot";
    DynamicUser = true;
    PrivateNetwork = false;
    PrivateTmp = true;
    SupplementaryGroups = [ "notify-ipc" ];
    UMask = "0007";
    ReadWritePaths = [ "/run/notify" ];
    LoadCredential = allCredentials;
  };

  deliveryPath = with pkgs; [ coreutils jq curl systemd findutils ];
in
{
  options.modules.notifications = {
    staleAfterMinutes = lib.mkOption {
      type = lib.types.ints.positive;
      default = 120;
      description = ''
        A payload older than this is archived to /run/notify/archive instead of
        being delivered, and reported in a single summary page.

        Delivery being restored after an outage must not fire the whole backlog
        at a phone: a burst of stale, mostly-resolved alerts is worse than
        useless, because it buries anything current. A month-old page is not
        actionable, but the fact that it went undelivered is - so the payloads
        are kept, and reported once, as a count rather than as pages.
      '';
    };

    backlogAlarm = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Alarm when notification payloads are not being delivered.

          A queue that stops draining is invisible by construction: every
          dispatch still exits 0, and the failure is the *absence* of a page.
          This watches the queue itself so that can never again be discovered by
          accident a month later.
        '';
      };

      afterMinutes = lib.mkOption {
        type = lib.types.ints.positive;
        default = 5;
        description = "How long a payload may sit undelivered before it is itself an alarm.";
      };

      intervalMinutes = lib.mkOption {
        type = lib.types.ints.positive;
        default = 5;
        description = "How often to check the queue.";
      };

      repeatHours = lib.mkOption {
        type = lib.types.ints.positive;
        default = 6;
        description = "Minimum gap between backlog pages, so a stuck queue does not become a pager storm.";
      };

      maxAttempts = lib.mkOption {
        type = lib.types.ints.positive;
        default = 5;
        description = ''
          How many delivery attempts a payload gets before it stops being
          retried and starts being reported as permanently undelivered.
        '';
      };
    };
  };

  config = lib.mkIf (cfg.enable && cfg.backends != { }) {
    systemd.tmpfiles.rules = [
      "d /run/notify/archive 0770 root notify-ipc -"
    ];

    # ---- The watcher ------------------------------------------------------
    # One glob over the whole directory, rather than one PathExists per
    # notification. wantedBy is correct here precisely because this is a real
    # unit and not a template: there is exactly one of it.
    systemd.paths.notify-drain = {
      description = "Watch for queued notification payloads";
      wantedBy = [ "multi-user.target" ];
      pathConfig = {
        # Temp files are written as *.json.tmp and renamed into place, so this
        # can never match a partially written payload.
        PathExistsGlob = "/run/notify/*.json";
      };
    };

    systemd.services.notify-drain = {
      description = "Deliver queued notification payloads";
      # Delivery needs the network; a path unit can fire during early boot.
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      path = deliveryPath;

      serviceConfig = deliveryServiceConfig // {
        TimeoutStartSec = "5min";
      };

      script = ''
        # Deliberately not `set -e`: one undeliverable payload must not abort
        # the drain and strand every payload behind it.
        set -uo pipefail
        shopt -s nullglob

        ${deliverFunctions}
        ${deliverDispatch}

        pending=0
        delivered=0
        quarantined=0
        archived=0
        ARCHIVED_LIST=""

        for PAYLOAD in /run/notify/*.json; do
          [ -f "$PAYLOAD" ] || continue
          pending=$((pending + 1))
          NAME=$(basename "$PAYLOAD")

          # Too old to be worth paging about. Archived, not deleted: an
          # undelivered alert is evidence of a real failure even when the
          # failure itself is long resolved.
          if [ -n "$(find "$PAYLOAD" -maxdepth 0 -mmin +${toString cfg.staleAfterMinutes} 2>/dev/null)" ]; then
            if mv -f "$PAYLOAD" "/run/notify/archive/$NAME" 2>/dev/null; then
              archived=$((archived + 1))
              # Only the first few are named. Backends cap message length, and a
              # list truncated mid-entry is worse than an honest count.
              if [ "$archived" -le 10 ]; then
                ARCHIVED_LIST="$ARCHIVED_LIST
        • ''${NAME%.json}"
              fi
            else
              echo "[notify] ERROR: could not archive stale payload $NAME" >&2
            fi
            continue
          fi

          if ! JSON=$(jq -e . "$PAYLOAD" 2>/dev/null); then
            echo "[notify] ERROR: $NAME is not valid JSON; quarantining" >&2
            mv -f "$PAYLOAD" "/run/notify/failed/$NAME" 2>/dev/null || rm -f "$PAYLOAD"
            quarantined=$((quarantined + 1))
            continue
          fi

          TITLE=$(printf '%s' "$JSON" | jq -r '.title // "Notification"')
          MESSAGE=$(printf '%s' "$JSON" | jq -r '.message // ""')
          PRIORITY=$(printf '%s' "$JSON" | jq -r '.priority // "normal"')
          BACKEND=$(printf '%s' "$JSON" | jq -r '.backend // ""')
          TEMPLATE=$(printf '%s' "$JSON" | jq -r '.template // ""')
          ATTEMPTS=$(printf '%s' "$JSON" | jq -r '.attempts // 0')

          # Payloads written directly by other units carry no backend field
          # (nixos-upgrade writes its own success payload, for example). Fall
          # back to the template's configured backend, then to the global
          # default, so an unlabelled payload still goes somewhere.
          if [ -z "$BACKEND" ]; then
            [ -n "$TEMPLATE" ] || TEMPLATE="''${NAME%.json}"
            TEMPLATE="''${TEMPLATE%%:*}"
            BACKEND=$(jq -r --arg t "$TEMPLATE" '.[$t].backend // empty' \
              /etc/notification-templates.json 2>/dev/null || true)
          fi
          [ -n "$BACKEND" ] || BACKEND="${cfg.defaultBackend}"

          export TITLE MESSAGE PRIORITY

          if deliver_to "$BACKEND"; then
            rm -f "$PAYLOAD"
            delivered=$((delivered + 1))
            echo "[notify] delivered $NAME via $BACKEND"
          else
            # Quarantined rather than left in place: a payload that keeps
            # failing would otherwise re-satisfy the path unit the instant the
            # drain exits and spin it in a hot loop. notify-backlog-check
            # requeues these on a timer and reports the ones that never land.
            echo "[notify] ERROR: delivery of $NAME via $BACKEND failed" >&2
            if printf '%s' "$JSON" \
              | jq -c --argjson n "$((ATTEMPTS + 1))" '. + {attempts: $n}' \
                > "/run/notify/failed/$NAME.tmp" 2>/dev/null; then
              chgrp notify-ipc "/run/notify/failed/$NAME.tmp" 2>/dev/null || true
              mv -f "/run/notify/failed/$NAME.tmp" "/run/notify/failed/$NAME"
              rm -f "$PAYLOAD"
            else
              mv -f "$PAYLOAD" "/run/notify/failed/$NAME" 2>/dev/null || rm -f "$PAYLOAD"
            fi
            quarantined=$((quarantined + 1))
          fi
        done

        # One summary instead of N stale pages.
        if [ "$archived" -gt 0 ]; then
          echo "[notify] archived $archived stale payload(s) to /run/notify/archive" >&2
          if [ "$archived" -gt 10 ]; then
            ARCHIVED_LIST="$ARCHIVED_LIST
        … and $((archived - 10)) more"
          fi
          TITLE="📼 ${cfg.hostname}: $archived undelivered notification(s) archived"
          MESSAGE="<b>Host:</b> ${cfg.hostname}
        <b>Archived:</b> $archived notification(s) older than ${toString cfg.staleAfterMinutes} minutes

        These were queued but never delivered. They are too old to page about
        individually, so they have been moved to /run/notify/archive rather
        than sent or discarded.
        $ARCHIVED_LIST

        <b>Review:</b> doas ls -la /run/notify/archive"
          PRIORITY="normal"
          export TITLE MESSAGE PRIORITY
          deliver_to "${cfg.defaultBackend}" \
            || echo "[notify] ERROR: archive summary could not be delivered" >&2
        fi

        echo "[notify] drain finished: $pending seen, $delivered delivered, $archived archived, $quarantined quarantined"

        # Backstop against a pathological loop: if anything is still sitting in
        # the watched directory (e.g. a payload we cannot unlink), the path unit
        # will re-trigger us immediately. Throttle rather than spin.
        leftover=( /run/notify/*.json )
        if [ ''${#leftover[@]} -gt 0 ]; then
          echo "[notify] WARNING: ''${#leftover[@]} payload(s) still queued after drain; throttling" >&2
          sleep 5
        fi
      '';
    };

    # ---- The queue watchdog ------------------------------------------------
    systemd.timers.notify-backlog-check = lib.mkIf backlogCfg.enable {
      description = "Periodically check for undelivered notifications";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "${toString backlogCfg.intervalMinutes}min";
        OnUnitActiveSec = "${toString backlogCfg.intervalMinutes}min";
        AccuracySec = "1min";
      };
    };

    systemd.services.notify-backlog-check = lib.mkIf backlogCfg.enable {
      description = "Alarm on undelivered notification payloads";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      path = deliveryPath;

      serviceConfig = deliveryServiceConfig // {
        TimeoutStartSec = "3min";
      };

      script = ''
        set -uo pipefail
        shopt -s nullglob

        ${deliverFunctions}
        ${deliverDispatch}

        STAMP=/run/notify/.backlog-alarm

        # Give quarantined payloads another go. Retrying here rather than in the
        # drain keeps attempts spaced by the timer interval instead of spinning
        # the path unit.
        requeued=0
        exhausted=0
        for FAILED in /run/notify/failed/*.json; do
          [ -f "$FAILED" ] || continue
          NAME=$(basename "$FAILED")
          ATTEMPTS=$(jq -r '.attempts // 0' "$FAILED" 2>/dev/null || echo ${toString backlogCfg.maxAttempts})
          if [ "$ATTEMPTS" -lt ${toString backlogCfg.maxAttempts} ]; then
            mv -f "$FAILED" "/run/notify/$NAME" && requeued=$((requeued + 1))
          else
            exhausted=$((exhausted + 1))
          fi
        done
        [ "$requeued" -eq 0 ] || echo "[notify] requeued $requeued quarantined payload(s) for retry"

        # A payload still sitting in the watched directory well after it was
        # written means the watcher is not doing its job. That is the exact
        # failure this module shipped with for a month, and it is the one
        # condition that cannot be reported by the queue itself.
        STALE=$(find /run/notify -maxdepth 1 -name '*.json' -type f \
          -mmin +${toString backlogCfg.afterMinutes} 2>/dev/null | wc -l)

        if [ "$STALE" -eq 0 ] && [ "$exhausted" -eq 0 ]; then
          exit 0
        fi

        SUMMARY=""
        [ "$STALE" -eq 0 ] || SUMMARY="$STALE payload(s) undelivered for over ${toString backlogCfg.afterMinutes} minutes"
        if [ "$exhausted" -gt 0 ]; then
          [ -z "$SUMMARY" ] || SUMMARY="$SUMMARY; "
          SUMMARY="$SUMMARY$exhausted payload(s) failed ${toString backlogCfg.maxAttempts} delivery attempts"
        fi

        echo "[notify] ALARM: notification delivery is broken: $SUMMARY" >&2
        find /run/notify -maxdepth 1 -name '*.json' -type f -printf '  pending: %f (%TY-%Tm-%Td %TH:%TM)\n' >&2 2>/dev/null || true
        find /run/notify/failed -maxdepth 1 -name '*.json' -type f -printf '  failed:  %f\n' >&2 2>/dev/null || true

        # Paged directly, never through the queue: an alarm about a broken
        # queue must not be enqueued into it.
        if [ ! -f "$STAMP" ] || [ -z "$(find "$STAMP" -newermt '-${toString backlogCfg.repeatHours} hours' 2>/dev/null)" ]; then
          TITLE="🚨 ${cfg.hostname}: notifications are not being delivered"
          MESSAGE="<b>Host:</b> ${cfg.hostname}
        <b>Problem:</b> $SUMMARY

        Notifications are queued in /run/notify but are not reaching a device,
        so other alarms from this host are currently silent.

        <b>Check:</b> systemctl status notify-drain.service
        <b>Queue:</b> doas ls -la /run/notify /run/notify/failed"
          PRIORITY="emergency"
          export TITLE MESSAGE PRIORITY
          if deliver_to "${cfg.defaultBackend}"; then
            touch "$STAMP"
            echo "[notify] backlog alarm delivered"
          else
            echo "[notify] ERROR: backlog alarm could not be delivered either" >&2
          fi
        fi

        # Fail the unit as well, so the backlog is visible to anything watching
        # systemd state even if no page can get out at all.
        exit 1
      '';
    };
  };
}
