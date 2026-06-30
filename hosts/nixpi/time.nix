# Time synchronisation for nixpi (the RV Raspberry Pi).
#
# This host is a mobile appliance: frequently off-grid (no NTP reachability) and
# its RTC currently has no battery, so every cold boot starts with a bogus clock.
# A wrong clock breaks TLS, cert validation, logs, and the Cloudflare tunnel.
#
# Strategy (layered, complementary sources):
#   1. GPS (gpsd -> chrony SHM refclock) — primary; works with NO network.
#   2. NTP (time.cloudflare.com, from modules.services.chrony) — used when online.
#   3. makestep — step a large offset on boot instead of slewing forever
#      (this is what kept the clock stuck ~557 days behind: chrony was only
#      slewing such a huge gap).
#   4. RTC battery (hardware, pending) — bridges gaps and gives GPS a warm start.
#
# Hardware: USB GPS on a Prolific PL2303 bridge, multi-constellation NMEA @ 38400
# baud (no PPS), so time accuracy is coarse (~0.1-0.5s) but more than enough for
# TLS/logs/dashboard. gpsd auto-detects the baud rate.
{ ... }:
{
  config = {
    services.gpsd = {
      enable = true;
      # Stable by-id path (the PL2303 exposes a serial number) so it survives
      # USB re-enumeration and moving ports. Resolves to /dev/ttyUSB0 today.
      devices = [ "/dev/serial/by-id/usb-Prolific_Technology_Inc._USB-Serial_Controller_AODPb115818-if00-port0" ];
      nowait = true; # -n: poll immediately without waiting for a client, so chrony's SHM refclock is fed.
      readonly = true; # -b: never write to the receiver (don't reconfigure it).
    };

    # chrony's extraConfig is types.lines and merges with the shared
    # modules.services.chrony definition (which keeps time.cloudflare.com as the
    # NTP source). We add the GPS refclock and stepping policy here.
    services.chrony.extraConfig = ''
      # GPS time shared by gpsd via SHM unit 0 (NMEA, no PPS). Coarse, so we give
      # it a generous delay: chrony prefers NTP when reachable and falls back to
      # GPS when the host is offline. Tune `offset` later if a constant NMEA
      # latency bias is observed.
      refclock SHM 0 refid GPS precision 1e-1 offset 0.0 delay 0.5

      # Batteryless RTC: allow chrony to STEP (not just slew) a large offset for
      # the first few updates after start, once any source (GPS fix or NTP) is
      # available. Without this a cold boot can stay wildly wrong indefinitely.
      makestep 1.0 3
    '';
  };
}
