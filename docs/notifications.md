# Centralized Notification System

## Overview

The centralized notification system provides a unified interface for sending notifications across multiple backends (Pushover, ntfy, Healthchecks.io) using the DRY methodology. Instead of hardcoding notification logic in each service, you can enable notifications once and use them throughout your system.

## Architecture

```
hosts/_modules/nixos/notifications/
├── default.nix          # Main module with unified interface
├── pushover.nix         # Pushover backend implementation
├── ntfy.nix             # ntfy backend implementation
└── healthchecks.nix     # Healthchecks.io backend implementation

lib/notification-helpers.nix  # Reusable helper functions
```

## Features

- **Multiple Backends**: Support for Pushover, ntfy, and Healthchecks.io
- **Unified Interface**: Single configuration, multiple backends
- **Pre-defined Templates**: Common notification patterns (backup, service failure, boot, disk alerts)
- **Secure Secret Management**: Integration with sops/age for API keys
- **Retry Logic**: Automatic retries with configurable timeouts
- **systemd Integration**: Easy to use with OnFailure hooks

## Quick Start

### 1. Enable Notification Module

```nix
# hosts/yourhost/default.nix
{
  modules.notifications = {
    enable = true;
    defaultBackend = "pushover";  # or "ntfy", "healthchecks", "all"

    pushover = {
      enable = true;
      tokenFile = config.sops.secrets.pushover-token.path;
      userKeyFile = config.sops.secrets.pushover-user-key.path;
      defaultPriority = 0;  # -2 to 2
      enableHtml = true;
    };

    # Enable notification templates
    templates = {
      backup-success.enable = true;
      backup-failure.enable = true;
      service-failure.enable = true;
      boot-notification.enable = true;
      disk-alert = {
        enable = true;
        threshold = 85;  # Alert when disk is 85% full
      };
    };
  };
}
```

### 2. Configure Secrets

Add to your `secrets.yaml`:

```yaml
# For Pushover
pushover-token: ENC[AES256_GCM,data:...]
pushover-user-key: ENC[AES256_GCM,data:...]

# For ntfy (if using authenticated topic)
# Usually not needed for public topics

# For Healthchecks.io
healthchecks-uuid: ENC[AES256_GCM,data:...]
```

Configure in your host:

```nix
sops.secrets = {
  pushover-token = {
    sopsFile = ./secrets.yaml;
    owner = "root";
    mode = "0400";
  };
  pushover-user-key = {
    sopsFile = ./secrets.yaml;
    owner = "root";
    mode = "0400";
  };
};
```

## Notification Backends

### Pushover

**Pros:**
- Rich HTML formatting
- Priority levels (-2 to 2)
- URL attachments with custom titles
- Device targeting
- Emergency priority with acknowledgment
- One-time $5 payment per platform

**Configuration:**

```nix
modules.notifications.pushover = {
  enable = true;
  tokenFile = config.sops.secrets.pushover-token.path;
  userKeyFile = config.sops.secrets.pushover-user-key.path;

  defaultPriority = 0;      # -2=lowest, -1=low, 0=normal, 1=high, 2=urgent
  defaultDevice = null;      # null = all devices, or specify device name
  enableHtml = true;         # Enable HTML formatting in messages
  retryAttempts = 3;        # Number of retry attempts
  timeout = 10;             # Timeout in seconds
};
```

**Setup:**
1. Create account at https://pushover.net (one-time $5 per platform)
2. Create an application/API token in dashboard
3. Get your user key from dashboard
4. Store in sops-encrypted secrets

### ntfy

**Pros:**
- Free and open source
- Self-hostable
- Simple topic-based subscriptions
- No account required for public topics
- Mobile apps and web interface

**Configuration:**

```nix
modules.notifications.ntfy = {
  enable = true;
  topic = "https://ntfy.sh/myserver-notifications";  # Or full URL
  server = "https://ntfy.sh";  # Use self-hosted server

  defaultPriority = "default";  # min, low, default, high, urgent
  retryAttempts = 3;
  timeout = 10;
};
```

**Setup:**
1. Choose a unique topic name (e.g., `myserver-alerts-$RANDOM`)
2. Subscribe to topic in ntfy mobile app or web interface
3. No authentication needed for public topics

### Healthchecks.io

**Pros:**
- Dead man's switch monitoring
- Tracks success and failure pings
- Grace periods and schedules
- Integration with many services
- Free tier available

**Configuration:**

```nix
modules.notifications.healthchecks = {
  enable = true;
  baseUrl = "https://hc-ping.com";
  uuidFile = config.sops.secrets.healthchecks-uuid.path;

  retryAttempts = 3;
  timeout = 10;
};
```

**Setup:**
1. Create account at https://healthchecks.io
2. Create a new check in dashboard
3. Copy the UUID from check URL
4. Store UUID in sops-encrypted secrets

## Pre-defined Templates

### Backup Success

Automatically notifies when backup completes successfully.

```nix
modules.notifications.templates.backup-success = {
  enable = true;
  priority = "normal";
};
```

**Usage:** Automatically triggered by backup module when `modules.backup.monitoring.enable = true`.

### Backup Failure

Sends high-priority alert when backup fails.

```nix
modules.notifications.templates.backup-failure = {
  enable = true;
  priority = "high";
};
```

**Usage:** Automatically triggered by backup module on failure.

### Service Failure

Alerts when any systemd service fails.

```nix
modules.notifications.templates.service-failure = {
  enable = true;
  priority = "high";
};
```

**Usage:** Attach to any service with:

```nix
systemd.services.myservice = {
  # ... service config ...
  onFailure = [ "notify-service-failure@%n.service" ];
};
```

### Boot Notification

Sends notification when system boots.

```nix
modules.notifications.templates.boot-notification = {
  enable = true;
  priority = "normal";
};
```

**Usage:** Automatically runs on boot when enabled.

### Disk Alert

Monitors disk usage and alerts when threshold exceeded.

```nix
modules.notifications.templates.disk-alert = {
  enable = true;
  threshold = 80;  # Alert at 80% full
  priority = "high";
};
```

**Usage:** Runs hourly via systemd timer when enabled.

## Advanced Usage

### Custom Notifications

Send custom notifications from scripts:

```bash
# Using Pushover backend
systemctl start notify-pushover@custom.service \
  --setenv=NOTIFY_TITLE="Custom Alert" \
  --setenv=NOTIFY_MESSAGE="Something happened!" \
  --setenv=NOTIFY_PRIORITY="high" \
  --setenv=NOTIFY_URL="https://example.com" \
  --setenv=NOTIFY_URL_TITLE="View Details"

# Using ntfy backend
systemctl start notify-ntfy@custom.service \
  --setenv=NOTIFY_TITLE="Custom Alert" \
  --setenv=NOTIFY_MESSAGE="Something happened!" \
  --setenv=NOTIFY_PRIORITY="high" \
  --setenv=NOTIFY_TAGS="warning,custom"
```

### Multiple Backends

Enable all backends to send to multiple services:

```nix
modules.notifications = {
  enable = true;
  defaultBackend = "all";  # Send to all enabled backends

  pushover.enable = true;
  ntfy.enable = true;
  healthchecks.enable = true;

  # Configure each backend...
};
```

### Backup Integration

The backup module automatically integrates with the notification system:

```nix
modules.backup = {
  enable = true;

  # Old ntfy-specific config is deprecated
  # monitoring.ntfy.enable = true;  # DON'T USE

  # Instead, enable centralized notifications
  monitoring.enable = true;

  # Notifications are sent via modules.notifications configuration
};

modules.notifications = {
  enable = true;
  pushover.enable = true;  # Or your preferred backend
  # ...
};
```

### Helper Functions

Use helper functions in your own modules:

```nix
{ config, lib, pkgs, ... }:
let
  notificationHelpers = import ../../../lib/notification-helpers.nix { inherit lib; };
in
{
  # Example: Create a monitoring service with notifications
  systemd.services.my-monitor = {
    description = "Monitor something important";
    script = ''
      if ! check_something; then
        ${notificationHelpers.mkCustomNotificationScript {
          title = "Monitor Alert";
          message = "Something is wrong!";
          priority = "high";
          backend = "pushover";
        }}
        exit 1
      fi
    '';

    # Or use OnFailure
    onFailure = [ "notify-service-failure@my-monitor.service" ];
  };
}
```

## Migration from ntfy

If you're currently using the old ntfy configuration in backup.nix:

### Before:

```nix
modules.backup.monitoring = {
  enable = true;
  ntfy = {
    enable = true;
    topic = "https://ntfy.sh/my-backups";
  };
};
```

### After:

```nix
# Enable centralized notifications
modules.notifications = {
  enable = true;
  defaultBackend = "pushover";  # or keep "ntfy"

  pushover = {
    enable = true;
    tokenFile = config.sops.secrets.pushover-token.path;
    userKeyFile = config.sops.secrets.pushover-user-key.path;
  };

  # Or keep using ntfy
  ntfy = {
    enable = true;
    topic = "https://ntfy.sh/my-backups";
  };

  templates = {
    backup-success.enable = true;
    backup-failure.enable = true;
  };
};

# Backup module automatically uses centralized notifications
modules.backup.monitoring.enable = true;
```

## Troubleshooting

### Check Notification Services

```bash
# List all notification services
systemctl list-units 'notify-*'

# Test Pushover notification
systemctl start notify-pushover@test.service \
  --setenv=NOTIFY_TITLE="Test" \
  --setenv=NOTIFY_MESSAGE="Test message"

# View logs
journalctl -u notify-pushover@test.service
```

### Verify Secret Files

```bash
# Check if secret files exist and have correct permissions
ls -la /run/secrets/pushover-*
cat /run/secrets/pushover-token  # Should show token
```

### Test Backend Manually

```bash
# Test Pushover API
curl -s \
  --form-string "token=$(cat /run/secrets/pushover-token)" \
  --form-string "user=$(cat /run/secrets/pushover-user-key)" \
  --form-string "message=Test from command line" \
  https://api.pushover.net/1/messages.json

# Test ntfy
curl -d "Test message" https://ntfy.sh/your-topic

# Test Healthchecks.io
curl -fsS -m 10 "https://hc-ping.com/$(cat /run/secrets/healthchecks-uuid)"
```

### Common Issues

**"Pushover token file not found"**
- Ensure sops secrets are configured correctly
- Check that secrets are decrypted to `/run/secrets/`
- Verify file permissions (should be readable by service user)

**"ntfy notification failed"**
- Check topic URL is correct
- Verify network connectivity
- Try accessing topic URL in browser

**"Healthchecks.io ping failed"**
- Verify UUID is correct
- Check that check exists in dashboard
- Ensure base URL is correct

## Security Best Practices

1. **Never commit secrets to git**
   - Always use sops/age for encryption
   - Use `.gitignore` for any secret files

2. **Restrict file permissions**
   ```nix
   sops.secrets.pushover-token = {
     mode = "0400";
     owner = "root";
   };
   ```

3. **Use dedicated app tokens**
   - Create separate Pushover apps for different services
   - Easier to track and revoke if needed

4. **Limit notification content**
   - Avoid including sensitive data in messages
   - Use URLs to link to detailed information instead

5. **Monitor notification delivery**
   - Check logs periodically: `journalctl -u notify-*`
   - Set up alerts for failed notifications

## Examples

### Example 1: Minimal Pushover Setup

```nix
{ config, ... }:
{
  # Secrets
  sops.secrets = {
    pushover-token.sopsFile = ./secrets.yaml;
    pushover-user-key.sopsFile = ./secrets.yaml;
  };

  # Notifications
  modules.notifications = {
    enable = true;
    pushover = {
      enable = true;
      tokenFile = config.sops.secrets.pushover-token.path;
      userKeyFile = config.sops.secrets.pushover-user-key.path;
    };
    templates = {
      backup-failure.enable = true;
      service-failure.enable = true;
      boot-notification.enable = true;
    };
  };
}
```

### Example 2: Multi-Backend Setup

```nix
{ config, ... }:
{
  modules.notifications = {
    enable = true;
    defaultBackend = "all";

    # Pushover for critical alerts
    pushover = {
      enable = true;
      tokenFile = config.sops.secrets.pushover-token.path;
      userKeyFile = config.sops.secrets.pushover-user-key.path;
      defaultPriority = 1;  # High priority by default
    };

    # ntfy for informational messages
    ntfy = {
      enable = true;
      topic = "https://ntfy.sh/myserver-info";
      defaultPriority = "low";
    };

    # Healthchecks.io for backup monitoring
    healthchecks = {
      enable = true;
      uuidFile = config.sops.secrets.healthchecks-uuid.path;
    };

    # Configure which templates use which backends
    templates = {
      backup-success = {
        enable = true;
        priority = "normal";
      };
      backup-failure = {
        enable = true;
        priority = "urgent";  # Highest priority for failures
      };
      boot-notification = {
        enable = true;
        priority = "low";
      };
    };
  };
}
```

### Example 3: Custom Service with Notifications

```nix
{ config, ... }:
{
  systemd.services.custom-health-check = {
    description = "Custom health monitoring";

    script = ''
      if ! curl -sf https://myservice.local/health; then
        echo "Health check failed!"
        exit 1
      fi
    '';

    serviceConfig = {
      Type = "oneshot";
    };

    # Send notification on failure
    onFailure = [ "notify-service-failure@custom-health-check.service" ];
  };

  systemd.timers.custom-health-check = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "minutely";
      Persistent = true;
    };
  };
}
```

## API Reference

See `lib/notification-helpers.nix` for available helper functions:

- `mkUnifiedNotification` - Send to multiple backends
- `mkBackupNotification` - Create backup event notifications
- `mkServiceFailureNotification` - Attach failure notifications to services
- `mkCustomNotificationScript` - Generate notification script
- `mkMultiBackendNotification` - Send to all enabled backends
- `mkMonitoringTimer` - Create monitoring timer with notifications

## Future Enhancements

Potential future additions:

- **Discord integration** - Webhook-based notifications
- **Slack integration** - Team notifications
- **Matrix integration** - Federated messaging
- **Email backend** - Traditional email notifications
- **Telegram integration** - Bot-based notifications
- **Webhook backend** - Generic HTTP POST notifications
- **Sound notifications** - Local audio alerts

## Contributing

To add a new notification backend:

1. Create `hosts/_modules/nixos/notifications/yourbackend.nix`
2. Follow the pattern in `pushover.nix` or `ntfy.nix`
3. Add options to `default.nix`
4. Update this documentation
5. Add helper functions to `lib/notification-helpers.nix`

## References

- [Pushover API Documentation](https://pushover.net/api)
- [ntfy Documentation](https://docs.ntfy.sh/)
- [Healthchecks.io Documentation](https://healthchecks.io/docs/)
- [systemd.service Documentation](https://www.freedesktop.org/software/systemd/man/systemd.service.html)
- [NixOS sops-nix](https://github.com/Mic92/sops-nix)
