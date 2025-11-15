{
  # Core system-level service configurations for forge
  # This file contains OS-level service configurations:
  # - rsyslogd: Omada device log relay to Loki
  # - journald: Persistent logging configuration

  # Rsyslog configuration for Omada device log relay
  # Receives syslog from Omada network devices and forwards to Loki
  services.rsyslogd = {
    enable = true;
    extraConfig = ''
      global(workDirectory="/var/spool/rsyslog")
      global(maxMessageSize="64k")

      # Load message modification module
      module(load="mmjsonparse")

      template(name="OmadaToRFC5424" type="string"
        string="<134>1 %timegenerated:::date-rfc3339% %fromhost% omada - - [omada@47450 src_ip=\"%fromhost-ip%\"] %$.cleanmsg%\n")

      # Unescaped message template for file sink (preserve embedded newlines)
      template(name="OmadaRawUnescaped" type="string"
        string="%timegenerated:::date-rfc3339% src_ip=%fromhost-ip% %$.cleanmsg%\n")

      ruleset(name="omada_devices") {
        # Convert Omada's literal CR/LF markers into real newlines and strip residuals
        set $.cleanmsg = replace($msg, "#015#012", "\n");
        set $.cleanmsg = replace($.cleanmsg, "#012", "\n");
        set $.cleanmsg = replace($.cleanmsg, "#015", "");
        # Split on newlines - rsyslog will process each line separately
        # The key is to configure the input to parse multi-line packets
        action(type="omfile" file="/var/log/omada-relay.log" template="OmadaToRFC5424")

        # Raw sink with unescaped newlines for Promtail file tailing
        action(type="omfile" file="/var/log/omada-raw.log" template="OmadaRawUnescaped")

        action(
          type="omfwd" Target="127.0.0.1" Port="1516" Protocol="udp" template="OmadaToRFC5424"
          queue.type="LinkedList" queue.size="10000" queue.dequeueBatchSize="200"
          action.resumeRetryCount="-1" action.resumeInterval="5"
        )
        stop
      }

      # UDP input for Omada syslog (rate limiting configured on input)
      module(load="imudp")
      input(
        type="imudp"
        port="1514"
        ruleset="omada_devices"
        # Rate limit to protect against bursts (set on input; not supported on module load)
        rateLimit.Interval="5"
        rateLimit.Burst="10000"
      )

      module(load="impstats" interval="60" severity="7" log.file="/var/log/rsyslog-stats.log")
    '';
  };

  # Enable persistent journald storage for log retention across reboots
  # Critical for disaster recovery operation visibility and debugging
  services.journald = {
    storage = "persistent";
    extraConfig = ''
      SystemMaxUse=500M
      RuntimeMaxUse=100M
      MaxFileSec=1month
    '';
  };

  # Fix journald startup race condition with impermanence bind mounts
  # Ensure journald waits for /var/log to be properly mounted before starting
  systemd.services.systemd-journald.unitConfig.RequiresMountsFor = [ "/var/log/journal" ];
}
