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
#
# This host also re-serves the GPS as NMEA 0183 over TCP on the LAN (port 10110)
# so devices that can't host their own GPS — e.g. a Victron Cerbo GX — can use
# the position without a receiver of their own.
{ pkgs, ... }:
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

    # Share GPS position on the LAN as NMEA 0183 over TCP.
    #
    # Venus OS / Cerbo GX has NO native network-GPS client — it only reads
    # USB/serial NMEA-0183 or NMEA-2000. So we publish the raw NMEA stream
    # (RMC/GGA/VTG/...) on port 10110 (the IANA "NMEA-0183 Navigational Data"
    # port); on the Cerbo you bridge this to a pseudo-serial with socat and point
    # gps_dbus at it. Also works directly with OpenCPN, SignalK, pyGPSClient, etc.
    #
    # `socat ... fork` spawns one `gpspipe -r` per client connection, each of
    # which streams the raw NMEA gpsd receives. DynamicUser is sufficient: the
    # only access it needs is gpsd's control socket on 127.0.0.1:2947.
    systemd.services.gps-nmea-tcp = {
      description = "Serve gpsd NMEA 0183 over TCP on the LAN (port 10110)";
      after = [ "gpsd.service" "network.target" ];
      wants = [ "gpsd.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        ExecStart = "${pkgs.socat}/bin/socat TCP-LISTEN:10110,reuseaddr,fork,keepalive EXEC:'${pkgs.gpsd}/bin/gpspipe -r'";
        Restart = "always";
        RestartSec = 5;
        DynamicUser = true;
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
      };
    };

    # LAN-only in practice: the Cloudflare tunnel is outbound, so nothing forwards
    # WAN traffic to this port — only devices on the RV LAN can reach it.
    networking.firewall.allowedTCPPorts = [ 10110 ];
  };
}
