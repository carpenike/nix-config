# Start-limit arithmetic for systemd units.
#
# THE PROBLEM
#
# systemd only marks a unit `failed` when StartLimitBurst start attempts land
# inside StartLimitIntervalSec. Consecutive attempts are spaced by
# (however long the service takes to fail + RestartSec), so a full burst spans
#
#   (StartLimitBurst - 1) * (failureDuration + RestartSec)
#
# and the limit is only reachable when that span fits inside the interval.
# With systemd's defaults (10s interval, burst 5, RestartSec=100ms) that caps
# the tolerated failure duration at 2.4 seconds. Anything slower restarts
# forever and never leaves `active`.
#
# On 2026-08-16 Home Assistant took ~3s to fail, so it crash-looped 367 times
# in 43 minutes while `systemctl is-active` reported `active` throughout. Both
# alerting paths missed it: the notify@ -> Pushover path is broken host-wide
# (tracked separately), and HomeAssistantServiceDown -- `for = "2m"` on
# node_systemd_unit_state{state="active"} == 0, see mkSystemdServiceDownAlert
# in lib/host-defaults.nix -- only ever reached `pending`, because a unit
# cycling active/activating is scraped as active most of the time. The longest
# contiguous run of zeroes was 60s against a 120s requirement.
#
# Bounding the window is what makes those alerts work: a unit that reaches
# `failed` stays at state="active" == 0 indefinitely, which satisfies the 2m
# threshold. 47 call sites of mkSystemdServiceDownAlert depend on this.
#
# Units with RestartSec >= 5s on the default window are worse still: 4 * 5s
# already exceeds the 10s interval, so they can NEVER reach `failed` no matter
# how fast they fail.
#
# THE FIX
#
# mkStartLimit inverts the arithmetic: given RestartSec and how long a start
# may take to fail, it returns a window in which the limit is actually
# reachable. Pass the result into a unit's `unitConfig` -- StartLimit* are
# [Unit] directives, and systemd silently ignores them in [Service].
#
# Pick failureBudget from the observed failure interval, not from taste. The
# default of 60s covers a service that spends up to a minute on I/O before
# giving up, which is the common case for anything touching a database or a
# network mount.
{ lib }:

{
  # restartSec: RestartSec in whole seconds. Round DOWN for sub-second values
  #   (pass 0 for the 100ms default) -- that shortens the window slightly,
  #   which is the safe direction.
  # failureBudget: how long a single start attempt may take to fail while the
  #   limit still remains reachable.
  mkStartLimit =
    { restartSec
    , failureBudget ? 60
    , burst ? 5
    ,
    }:
      assert lib.assertMsg (burst >= 2) "mkStartLimit: burst must be >= 2 (a burst of 1 trips on the first start)";
      {
        StartLimitBurst = burst;
        # +1 so the final attempt lands inside the window rather than exactly on
        # its edge.
        StartLimitIntervalSec = (burst - 1) * (restartSec + failureBudget) + 1;
      };

  # For units where giving up is worse than looping forever: remote access,
  # network tunnels, agents that fail until the network comes up.
  #
  # Setting this explicitly is the point. Every one of these units currently
  # gets infinite restart *by accident*, because the default window is
  # unreachable for its RestartSec -- indistinguishable from an oversight.
  # Declaring it makes the intent reviewable. Same idea as the existing
  # `startLimitIntervalSec = 0` in modules/nixos/services/emqx/default.nix.
  neverGiveUp = {
    StartLimitIntervalSec = 0;
  };
}
