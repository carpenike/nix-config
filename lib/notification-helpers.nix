{ lib }:

rec {
  # Create a unified notification service that can send to multiple backends
  mkUnifiedNotification = {
    name,
    title ? "",
    message ? "",
    priority ? "normal",
    backends ? [ "pushover" ], # List of backends to use
    enabledBackends ? {}, # Which backends are actually enabled
    ...
  }: {
    "notify-${name}" = {
      description = "Send ${name} notification";

      serviceConfig = {
        Type = "oneshot";
        DynamicUser = true;
        PrivateNetwork = false;
        PrivateTmp = true;
      };

      script = lib.concatStringsSep "\n\n" (
        lib.flatten [
          # Send to Pushover if enabled and in backends list
          (lib.optional
            (lib.elem "pushover" backends && enabledBackends.pushover or false)
            "systemctl start notify-pushover@${name}.service || true"
          )

          # Send to ntfy if enabled and in backends list
          (lib.optional
            (lib.elem "ntfy" backends && enabledBackends.ntfy or false)
            "systemctl start notify-ntfy@${name}.service || true"
          )

          # Send to Healthchecks if enabled and in backends list
          (lib.optional
            (lib.elem "healthchecks" backends && enabledBackends.healthchecks or false)
            "systemctl start healthcheck-ping@${name}.service || true"
          )
        ]
      );
    };
  };

  # Helper to create a notification for backup events
  mkBackupNotification = {
    jobName,
    eventType, # "success", "failure", "start"
    backends ? [ "pushover" ],
    enabledBackends ? {},
  }:
    let
      serviceSuffix = if eventType == "success" then "backup-success"
                      else if eventType == "failure" then "backup-failure"
                      else if eventType == "start" then "backup-start"
                      else "backup-${eventType}";
    in {
      # Create systemd service that triggers appropriate backend services
      "notify-${serviceSuffix}@${jobName}" = {
        description = "Backup ${eventType} notification for ${jobName}";

        serviceConfig = {
          Type = "oneshot";
        };

        script = lib.concatStringsSep "\n" (
          lib.flatten [
            # Pushover notifications
            (lib.optional
              (lib.elem "pushover" backends && enabledBackends.pushover or false)
              "systemctl start notify-backup-${eventType}@${jobName}.service || true"
            )

            # ntfy notifications
            (lib.optional
              (lib.elem "ntfy" backends && enabledBackends.ntfy or false)
              "systemctl start notify-ntfy-backup-${eventType}@${jobName}.service || true"
            )

            # Healthchecks.io pings
            (lib.optional
              (lib.elem "healthchecks" backends && enabledBackends.healthchecks or false)
              "systemctl start healthcheck-backup-${eventType}@${jobName}.service || true"
            )
          ]
        );
      };
    };

  # Helper to attach OnFailure notification to a service
  mkServiceFailureNotification = {
    serviceName,
    backends ? [ "pushover" ],
    enabledBackends ? {},
  }: {
    systemd.services.${serviceName} = {
      onFailure = lib.mkMerge [
        (lib.mkIf (lib.elem "pushover" backends && enabledBackends.pushover or false)
          [ "notify-service-failure@${serviceName}.service" ]
        )
        (lib.mkIf (lib.elem "ntfy" backends && enabledBackends.ntfy or false)
          [ "notify-ntfy-service-failure@${serviceName}.service" ]
        )
      ];
    };
  };

  # Helper to create a custom notification script
  mkCustomNotificationScript = {
    title,
    message,
    priority ? "normal",
    backend ? "pushover",
    # Additional backend-specific options
    url ? null,
    urlTitle ? null,
    tags ? [],
  }:
    if backend == "pushover" then ''
      systemctl start notify-pushover@custom.service \
        --setenv=NOTIFY_TITLE="${title}" \
        --setenv=NOTIFY_MESSAGE="${message}" \
        --setenv=NOTIFY_PRIORITY="${priority}" \
        ${lib.optionalString (url != null) ''--setenv=NOTIFY_URL="${url}"''} \
        ${lib.optionalString (urlTitle != null) ''--setenv=NOTIFY_URL_TITLE="${urlTitle}"''}
    ''
    else if backend == "ntfy" then ''
      systemctl start notify-ntfy@custom.service \
        --setenv=NOTIFY_TITLE="${title}" \
        --setenv=NOTIFY_MESSAGE="${message}" \
        --setenv=NOTIFY_PRIORITY="${priority}" \
        ${lib.optionalString (tags != []) ''--setenv=NOTIFY_TAGS="${lib.concatStringsSep "," tags}"''} \
        ${lib.optionalString (url != null) ''--setenv=NOTIFY_URL="${url}"''}
    ''
    else if backend == "healthchecks" then ''
      systemctl start healthcheck-ping@custom.service \
        --setenv=HC_STATUS="${if priority == "high" || priority == "urgent" then "fail" else "success"}" \
        --setenv=HC_MESSAGE="${title}: ${message}"
    ''
    else
      throw "Unknown notification backend: ${backend}";

  # Helper to send notifications to all enabled backends
  mkMultiBackendNotification = {
    title,
    message,
    priority ? "normal",
    enabledBackends ? {},
    url ? null,
    urlTitle ? null,
    tags ? [],
  }: lib.concatStringsSep "\n\n" (
    lib.flatten [
      (lib.optional (enabledBackends.pushover or false)
        (mkCustomNotificationScript {
          inherit title message priority url urlTitle;
          backend = "pushover";
        })
      )
      (lib.optional (enabledBackends.ntfy or false)
        (mkCustomNotificationScript {
          inherit title message priority tags url;
          backend = "ntfy";
        })
      )
      (lib.optional (enabledBackends.healthchecks or false)
        (mkCustomNotificationScript {
          inherit title message priority;
          backend = "healthchecks";
        })
      )
    ]
  );

  # Helper to create a monitoring timer with notifications
  mkMonitoringTimer = {
    name,
    description,
    schedule, # systemd OnCalendar format
    monitoringScript,
    notifyOnFailure ? true,
    backends ? [ "pushover" ],
    enabledBackends ? {},
  }: {
    systemd.timers."monitor-${name}" = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = schedule;
        Persistent = true;
      };
    };

    systemd.services."monitor-${name}" = {
      inherit description;

      serviceConfig = {
        Type = "oneshot";
      };

      script = monitoringScript;

      onFailure = lib.mkIf notifyOnFailure (
        lib.flatten [
          (lib.optional (lib.elem "pushover" backends && enabledBackends.pushover or false)
            "notify-service-failure@monitor-${name}.service"
          )
          (lib.optional (lib.elem "ntfy" backends && enabledBackends.ntfy or false)
            "notify-ntfy-service-failure@monitor-${name}.service"
          )
        ]
      );
    };
  };

  # Priority conversion helpers
  stringToPushoverPriority = priority:
    if priority == "lowest" then -2
    else if priority == "low" then -1
    else if priority == "normal" then 0
    else if priority == "high" then 1
    else if priority == "urgent" then 2
    else 0;

  stringToNtfyPriority = priority:
    if priority == "lowest" || priority == "min" then "min"
    else if priority == "low" then "low"
    else if priority == "normal" then "default"
    else if priority == "high" then "high"
    else if priority == "urgent" then "urgent"
    else "default";

  # Validation helpers
  validateNotificationConfig = cfg:
    let
      hasAnyBackend = cfg.pushover.enable or cfg.ntfy.enable or cfg.healthchecks.enable;
      pushoverValid = !cfg.pushover.enable ||
        (cfg.pushover.tokenFile != null && cfg.pushover.userKeyFile != null);
      ntfyValid = !cfg.ntfy.enable || cfg.ntfy.topic != "";
      healthchecksValid = !cfg.healthchecks.enable || cfg.healthchecks.uuidFile != null;
    in {
      assertions = [
        {
          assertion = !cfg.enable || hasAnyBackend;
          message = "At least one notification backend must be enabled when notifications are enabled";
        }
        {
          assertion = pushoverValid;
          message = "Pushover requires tokenFile and userKeyFile to be set";
        }
        {
          assertion = ntfyValid;
          message = "ntfy requires topic to be set";
        }
        {
          assertion = healthchecksValid;
          message = "Healthchecks.io requires uuidFile to be set";
        }
      ];
    };
}
