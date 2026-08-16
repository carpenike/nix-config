{ config, lib, ... }:
# Crash-loop detection for forge
#
# WHY THIS FILE EXISTS
#
# forge has 44 per-service ServiceDown alerts of the form
#
#     node_systemd_unit_state{name="<unit>.service",state="active"} == 0   for 2m
#
# plus the host-wide SystemdUnitFailed alert. Every one of them requires the
# unit to *stay* non-active. A crash-looping unit does not: it cycles through
# activating -> active -> failed-start every couple of seconds, so most scrapes
# sample it as active and the alert never leaves "pending".
#
# systemd will park a unit in `failed` and stop the loop, but only once
# StartLimitBurst starts have occurred inside StartLimitIntervalSec. Those
# N starts are spread over (N - 1) * (failure duration + RestartSec), so the
# systemd default of 10s / 5 starts is reachable only for failures under 2.4s,
# and is unreachable at any speed once RestartSec >= 2.5s.
#
# Home Assistant proved this on 2026-08-16: 367 restarts over 43 minutes, the
# longest contiguous run of state != active was 60s against the 120s `for`, and
# HomeAssistantServiceDown went pending and reset for the entire outage without
# ever firing. Two independent alerting paths existed and neither delivered.
#
# forgeDefaults.mkCrashLoopLimit sizes the window from each unit's own restart
# timing (see lib/host-defaults.nix for the arithmetic). Widening the window
# does not make a unit restart less - it makes the burst *reachable*, so a
# genuinely broken unit lands in `failed`, where all three existing paths
# (ServiceDown, SystemdUnitFailed, OnFailure=notify@) can finally see it.
#
# NOT LISTED HERE
#
# Units left alone keep restarting forever on purpose; they are covered by the
# SystemdUnitCrashLooping alert in core/monitoring.nix, which watches restart
# churn directly and needs no behaviour change:
#
#   cloudflared-forge     retries until the network/edge is reachable
#   github-runner-forge   Restart=on-success is the job loop, not a failure loop
#   postgresql            every other service depends on it; keep retrying
#
let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };

  # Units whose crash-loops must become visible. Each has a ServiceDown alert
  # and a Restart= policy that can loop. RestartSec is read from the unit
  # itself, so this table never drifts out of sync with it; `failureSec` is the
  # only tuning knob - how long a broken start may survive before dying.
  #
  # The 60s default covers everything measured on forge (Home Assistant took
  # ~3s). Raise it for services that fail slowly rather than lowering it.
  protectedUnits = {
    actual = { };
    ambit = { };
    beszel-agent = { };
    cooklang = { };
    cooklang-federation = { };
    filebrowser-quantum = { };
    gatus = { };
    glances-web = { };
    grafana = { };
    hermes-agent = { };
    # The module carries its own 300/5 baseline as mkDefault (#820) so any host
    # gets a usable window. Listing it here makes forge the owner of the number
    # without conflicting - the derived value is the same 300, and a future
    # failureSec change here simply wins over the default.
    home-assistant = { };
    homelab-mcp = { };
    homepage-dashboard = { };
    lading = { };
    marginalia = { };
    miniflux = { };
    phpfpm-grocy = { };
    pinchflat = { };
    pocket-id = { };
    podman-bgutil-pot = { };
    podman-emqx = { };
    podman-valhalla = { };
    replog = { };
    schoolhouse = { };
    tautulli = { };
    whiskey-whiskey-whiskey = { };
    worldmonitor-api = { };
    zigbee2mqtt = { };
    zwave-js-ui = { };

    # Paperless runs Django migrations on every start; a broken start can sit in
    # migrate/collectstatic well past a minute before giving up.
    paperless-consumer = { failureSec = 180; };
    paperless-scheduler = { failureSec = 180; };
    paperless-task-queue = { failureSec = 180; };
    paperless-web = { failureSec = 180; };
  };

  # RestartSec as systemd accepts it: a bare number is seconds, otherwise a
  # suffixed duration. Unset means systemd's 100ms default, which rounds to 0 -
  # the 25% headroom in mkCrashLoopLimit absorbs the difference.
  unitSeconds = {
    ms = 0; # sub-second, below the resolution this arithmetic needs
    s = 1;
    sec = 1;
    m = 60;
    min = 60;
    h = 3600;
  };

  parseSeconds =
    raw:
    let
      matched = builtins.match "([0-9]+)(min|sec|ms|s|m|h)?" (toString raw);
      count = lib.toInt (builtins.elemAt matched 0);
      suffix = builtins.elemAt matched 1;
      unit = if suffix == null then "s" else suffix;
    in
    if raw == null then 0 else if matched == null then null else count * unitSeconds.${unit};

  restartSecOf =
    unit:
    parseSeconds (config.systemd.services.${unit}.serviceConfig.RestartSec or null);

  hasUnit = unit: config.systemd.services ? ${unit};

  restartsOf =
    unit: config.systemd.services.${unit}.serviceConfig.Restart or null;

  # Every alert mkSystemdServiceDownAlert produces, reduced back to the unit it
  # watches. An alert naming a unit that does not exist on this host scrapes no
  # metric at all, so `== 0` is never true and the alert is silently dead -
  # cloudflared, emqx and searx were all in that state before this check.
  downAlertPrefix = ''node_systemd_unit_state{name="'';
  downAlertSuffix = ''.service",state="active"} == 0'';

  downAlertUnits = lib.concatMap
    (rule:
      let expr = rule.expr or ""; in
      lib.optional (lib.hasPrefix downAlertPrefix expr && lib.hasSuffix downAlertSuffix expr)
        (lib.removeSuffix downAlertSuffix (lib.removePrefix downAlertPrefix expr)))
    (lib.attrValues config.modules.alerting.rules);
in
{
  systemd.services = lib.mapAttrs
    (unit: opts:
      forgeDefaults.mkCrashLoopLimit ({ restartSec = restartSecOf unit; } // opts))
    protectedUnits;

  assertions =
    # Every protected unit must have a Restart= policy.
    #
    # This doubles as the typo/rename guard. There is deliberately no separate
    # "does the unit exist" check: defining startLimitIntervalSec above *creates*
    # systemd.services.<name>, so an existence test on a misspelled name would
    # always pass and always be useless. A conjured unit has no Restart= though,
    # so a bad name lands here instead - the same way beszel.service ended up as
    # an empty unit elsewhere in this config.
    (lib.mapAttrsToList
      (unit: _: {
        assertion = !(builtins.elem (restartsOf unit) [ null "no" ]);
        message = ''
          crash-loop-detection: systemd.services."${unit}" has Restart=${toString (restartsOf unit)},
          so a start limit has no effect. Either the unit name is wrong (in which
          case this file has just created an empty unit under that name) or it
          genuinely never restarts. Fix or drop the entry in
          hosts/forge/core/crash-loop-detection.nix.
        '';
      })
      protectedUnits)

    # An unparseable RestartSec would silently size the window from 0.
    ++ (lib.mapAttrsToList
      (unit: _: {
        assertion = restartSecOf unit != null;
        message = ''
          crash-loop-detection: cannot parse RestartSec for systemd.services."${unit}".
          Teach parseSeconds the new duration form in
          hosts/forge/core/crash-loop-detection.nix.
        '';
      })
      protectedUnits)

    ++ (map
      (unit: {
        assertion = hasUnit unit;
        message = ''
          alerting: a ServiceDown alert watches "${unit}.service", which is not a unit
          on this host. node_systemd_unit_state is never exported for it, so the alert
          can never fire. Correct the service name passed to
          forgeDefaults.mkSystemdServiceDownAlert.
        '';
      })
      downAlertUnits);
}
