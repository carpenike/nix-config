{ lib
, config
, pkgs
, ...
}:
let
  cfg = config.modules.notifications;

  # Placeholders the dispatcher always resolves by itself, without any help
  # from the caller. Anything else a template references must be declared in
  # that template's `placeholders` list and supplied at dispatch time via
  # `modules.notifications.context` (static) or a runtime context file.
  builtinPlaceholders = [
    "hostname"
    "serviceName"
    "template"
    "instance"
    "timestamp"
    # Derived from the failed unit when the instance names one
    "errormessage"
    "dataset"
    "jobname"
    "repository"
  ];

  # Pull every ''${...} occurrence out of a template string. Deliberately
  # matches ANY brace content, not just valid identifiers, so that shell-isms
  # such as ''${dataset:-"unknown"} and stray Nix expressions such as
  # ''${config.networking.hostName} are caught rather than silently passed
  # through to the rendered message.
  extractPlaceholders = str:
    lib.concatMap (p: if builtins.isList p then p else [ ])
      (builtins.split "\\$\\{([^}]*)\\}" str);

  # Placeholder names are substituted by exact match, so they must be plain
  # identifiers. Anything else can never resolve.
  isIdentifier = name: builtins.match "[a-zA-Z_][a-zA-Z0-9_]*" name != null;

  templateProblems = name: template:
    let
      allowed = builtinPlaceholders ++ template.placeholders;
      used = extractPlaceholders template.title ++ extractPlaceholders template.body;
      malformed = lib.filter (p: !isIdentifier p) used;
      undeclared = lib.filter (p: isIdentifier p && !lib.elem p allowed) used;
      hasCommandSubst =
        lib.hasInfix "$(" template.title || lib.hasInfix "$(" template.body;
    in
    lib.optional (malformed != [ ])
      (
        "notification template '${name}' uses placeholder(s) that can never resolve: "
        + lib.concatMapStringsSep ", " (p: "\${${p}}") malformed
        + ". Placeholders are substituted by exact name, so only plain identifiers work. "
        + "In a Nix indented string, ''\${foo} emits a literal \${foo}; use \${foo} "
        + "(unescaped) if you meant to interpolate a Nix value at build time."
      )
    ++ lib.optional (undeclared != [ ]) (
      "notification template '${name}' references undeclared placeholder(s): "
      + lib.concatMapStringsSep ", " (p: "\${${p}}") undeclared
      + ". Either use one of the built-ins (${lib.concatStringsSep ", " builtinPlaceholders}) "
      + "or declare them in this template's `placeholders` list and supply them via "
      + "`modules.notifications.context` or a runtime context file."
    )
    ++ lib.optional hasCommandSubst (
      "notification template '${name}' contains a shell command substitution '$(...)'. "
      + "Template bodies are rendered by literal placeholder substitution, not by a shell, "
      + "so this would be delivered verbatim. Use \${timestamp} or a declared placeholder."
    );
in
{
  imports = [
    ./drain.nix
    ./pushover.nix
    ./ntfy.nix
    ./healthchecks.nix
  ];

  options.modules.notifications = {
    enable = lib.mkEnableOption "centralized notification system";

    defaultBackend = lib.mkOption {
      type = lib.types.enum [ "pushover" "ntfy" "healthchecks" "all" ];
      default = "pushover";
      description = "Default notification backend to use when not specified";
    };

    # Common notification options
    hostname = lib.mkOption {
      type = lib.types.str;
      default = config.networking.hostName;
      description = "Hostname to include in notifications";
    };

    # Distributed template system - services register their own templates
    templates = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          enable = lib.mkEnableOption "this notification template" // { default = true; };

          priority = lib.mkOption {
            type = lib.types.enum [ "emergency" "high" "normal" "low" "silent" ];
            default = "normal";
            description = ''
              Notification priority level:
              - emergency (2): Bypass quiet hours, require acknowledgment
              - high (1): Important but not critical
              - normal (0): Standard notifications
              - low (-1): No sound/vibration, show in notification center
              - silent (-2): No notification, log only
            '';
          };

          title = lib.mkOption {
            type = lib.types.str;
            description = "Title of the notification message. Can use placeholders like \${hostname}, \${serviceName}";
          };

          placeholders = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            example = [ "pool" "state" ];
            description = ''
              Extra placeholder names this template's title/body may reference,
              beyond the built-ins (${lib.concatStringsSep ", " builtinPlaceholders}).

              Every placeholder used must be either a built-in or listed here;
              otherwise evaluation fails. This is what stops a template from
              silently rendering a blank service name or a literal
              "''${config.networking.hostName}" in a real page.

              Declared placeholders must be supplied at dispatch time, either
              statically via `modules.notifications.context.<unit>` or at runtime
              by writing /run/notify/ctx/<template>:<instance>.json before
              starting notify@<template>:<instance>.service. Anything still
              unresolved is rendered as "(unset: name)" rather than silently
              dropped.
            '';
          };

          body = lib.mkOption {
            type = lib.types.lines;
            description = "Body of the notification message. Can use HTML formatting if backend supports it";
          };

          backend = lib.mkOption {
            type = lib.types.enum [ "pushover" "ntfy" "healthchecks" "all" ];
            default = cfg.defaultBackend;
            description = "Which backend(s) to use for this template";
          };

          # Template-specific options
          extraOptions = lib.mkOption {
            type = lib.types.attrs;
            default = { };
            description = "Additional template-specific options (e.g., disk threshold, retry count)";
          };
        };
      });
      default = { };
      description = ''
        Notification templates registered by service modules.
        Services define their own templates here using mkDefault for easy override.

        Example from backup.nix:
          modules.notifications.templates.backup-failure = {
            enable = lib.mkDefault true;
            priority = lib.mkDefault "high";
            title = "Backup Failed";
            body = "...";
          };
      '';
    };

    context = lib.mkOption {
      type = lib.types.attrsOf (lib.types.attrsOf lib.types.str);
      default = { };
      example = lib.literalExpression ''
        { "syncoid-tank-services-plex.service".targetHost = "vault"; }
      '';
      description = ''
        Static placeholder values, keyed by the instance info the dispatcher is
        called with (for OnFailure handlers using %n, that is the failed unit
        name).

        This exists for context that is known at build time but cannot be
        written at dispatch time. An OnFailure handler gets no chance to run
        code before the notifier fires, so it cannot write a runtime context
        file; anything it needs must be declared here instead.
      '';
    };

    # Delivery backends register themselves here so the drain can route a
    # payload without knowing which backends exist. Adding a backend must not
    # require touching the drain.
    backends = lib.mkOption {
      internal = true;
      default = { };
      description = "Registered delivery backends, populated by backend modules.";
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          credentials = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            description = "LoadCredential entries this backend needs to deliver.";
          };
          deliver = lib.mkOption {
            type = lib.types.lines;
            description = ''
              Shell body that delivers one notification. It may read TITLE,
              MESSAGE and PRIORITY from the environment and must exit non-zero
              if delivery did not happen.
            '';
          };
        };
      });
    };

    # Backend configurations are defined in their respective modules
    pushover = lib.mkOption {
      type = lib.types.submodule {
        options = {
          enable = lib.mkEnableOption "Pushover notifications";

          tokenFile = lib.mkOption {
            type = lib.types.nullOr lib.types.path;
            default = null;
            description = "Path to file containing Pushover API token";
          };

          userKeyFile = lib.mkOption {
            type = lib.types.nullOr lib.types.path;
            default = null;
            description = "Path to file containing Pushover user key";
          };

          defaultPriority = lib.mkOption {
            type = lib.types.int;
            default = 0;
            description = "Default priority level (-2 to 2)";
          };

          defaultDevice = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Default device to send notifications to (null = all devices)";
          };

          enableHtml = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Enable HTML formatting in messages";
          };

          retryAttempts = lib.mkOption {
            type = lib.types.int;
            default = 3;
            description = "Number of retry attempts for failed notifications";
          };

          timeout = lib.mkOption {
            type = lib.types.int;
            default = 10;
            description = "Timeout in seconds for notification requests";
          };
        };
      };
      default = { };
      description = "Pushover notification backend configuration";
    };

    ntfy = lib.mkOption {
      type = lib.types.submodule {
        options = {
          enable = lib.mkEnableOption "ntfy notifications";

          topic = lib.mkOption {
            type = lib.types.str;
            default = "";
            description = "ntfy.sh topic URL for notifications";
          };

          server = lib.mkOption {
            type = lib.types.str;
            default = "https://ntfy.sh";
            description = "ntfy server URL";
          };

          defaultPriority = lib.mkOption {
            type = lib.types.str;
            default = "default";
            description = "Default priority (min, low, default, high, urgent)";
          };

          retryAttempts = lib.mkOption {
            type = lib.types.int;
            default = 3;
            description = "Number of retry attempts for failed notifications";
          };

          timeout = lib.mkOption {
            type = lib.types.int;
            default = 10;
            description = "Timeout in seconds for notification requests";
          };
        };
      };
      default = { };
      description = "ntfy notification backend configuration";
    };

    healthchecks = lib.mkOption {
      type = lib.types.submodule {
        options = {
          enable = lib.mkEnableOption "Healthchecks.io monitoring";

          baseUrl = lib.mkOption {
            type = lib.types.str;
            default = "https://hc-ping.com";
            description = "Healthchecks.io base URL";
          };

          uuidFile = lib.mkOption {
            type = lib.types.nullOr lib.types.path;
            default = null;
            description = "Path to file containing Healthchecks.io UUID";
          };

          retryAttempts = lib.mkOption {
            type = lib.types.int;
            default = 3;
            description = "Number of retry attempts for failed pings";
          };

          timeout = lib.mkOption {
            type = lib.types.int;
            default = 10;
            description = "Timeout in seconds for ping requests";
          };
        };
      };
      default = { };
      description = "Healthchecks.io monitoring configuration";
    };
  };

  config = lib.mkIf cfg.enable {
    # Fail the build on a template that could only ever render garbage.
    # Root cause of the month-long outage was a template whose contract read
    # correct and whose output was blank; nothing checked it until a human did.
    assertions =
      let
        problems = lib.concatLists (
          lib.mapAttrsToList templateProblems (lib.filterAttrs (_: t: t.enable) cfg.templates)
        );
      in
      map (p: { assertion = false; message = p; }) problems
      ++ [{
        assertion = cfg.backends != { };
        message =
          "modules.notifications.enable is true but no delivery backend is enabled. "
          + "Payloads would queue in /run/notify and never be delivered. "
          + "Enable one of modules.notifications.{pushover,ntfy,healthchecks}.";
      }];

    # Create a dedicated group for notification services to share files securely
    # Using 'notify-ipc' to avoid conflicts with DynamicUser creating groups named 'notify'
    users.groups.notify-ipc = { };

    # Create payload directory for IPC between notification services
    # Using 1770 (rwxrwx--T with sticky bit) for secure shared drop-box pattern:
    # - Only services in the 'notify-ipc' group can read/write files (group access only)
    # - Sticky bit prevents services from deleting each other's files
    # - Files are created with 0660 (rw-rw----) via UMask=0007
    # Pending payloads live directly in /run/notify; the drain watches that
    # directory with a glob. Subdirectories are deliberately outside the glob:
    # ctx/ holds caller-supplied context awaiting dispatch, failed/ quarantines
    # payloads that could not be delivered so a permanent failure cannot spin
    # the path unit in a hot retry loop.
    systemd.tmpfiles.rules = [
      "d /run/notify 0770 root notify-ipc -"
      "d /run/notify/ctx 0770 root notify-ipc -"
      "d /run/notify/failed 0770 root notify-ipc -"
    ];

    # Ensure directories exist during nixos-rebuild switch (activation time)
    # This complements tmpfiles which runs at boot
    system.activationScripts.createNotifyDirs = {
      text = ''
        # Ensure runtime directories exist for newly started services during activation
        ${pkgs.coreutils}/bin/install -d -m 0770 -g notify-ipc /run/notify
        ${pkgs.coreutils}/bin/install -d -m 0770 -g notify-ipc /run/notify/ctx
        ${pkgs.coreutils}/bin/install -d -m 0770 -g notify-ipc /run/notify/failed
      '';
      deps = [ "users" ]; # Ensures users/groups are created first
    };

    # Generate a JSON file containing all registered template definitions
    # This is used by the generic dispatcher to look up template details
    environment.etc."notification-templates.json".text = builtins.toJSON (
      lib.mapAttrs
        (_name: template: {
          inherit (template) enable priority backend title body placeholders;
          extraOptions = template.extraOptions or { };
        })
        cfg.templates
    );

    # Build-time placeholder values, keyed by instance info (usually a unit name)
    environment.etc."notification-context.json".text = builtins.toJSON cfg.context;

    # Generic notification dispatcher service
    # Services call this as: notify@template-name:instance-info.service
    # Example: notify@backup-failure:system-job.service
    systemd.services."notify@" = {
      description = "Notification dispatcher for %I";
      path = with pkgs; [ coreutils jq bash curl systemd gawk ];

      serviceConfig = {
        Type = "oneshot";
        DynamicUser = true;
        # Join the notify-ipc group to access the shared IPC directory
        SupplementaryGroups = [ "notify-ipc" ];
        # Create files with 0660 permissions (rw-rw----) for group-only access
        UMask = "0007";
        # DynamicUser enables ProtectSystem=strict by default, making most paths read-only
        # Explicitly allow writes to /run/notify for IPC
        ReadWritePaths = [ "/run/notify" ];
      };

      # Pass %i as command-line argument - systemd expands it in ExecStart directive
      scriptArgs = "%i";

      script = ''
        set -euo pipefail

        # Parse the instance string: template-name:instance-info
        # Receive instance string as $1 (passed via scriptArgs)
        INSTANCE_STRING="$1"
        TEMPLATE_NAME="''${INSTANCE_STRING%%:*}"
        # An instance string with no colon (e.g. "nixos-upgrade-failure") has no
        # instance info at all. `cut -d: -f2-` used to echo the whole string back
        # here, so serviceName silently became the template name.
        if [ "$INSTANCE_STRING" = "$TEMPLATE_NAME" ]; then
          INSTANCE_INFO=""
        else
          INSTANCE_INFO="''${INSTANCE_STRING#*:}"
        fi

        echo "[notify] Dispatching notification for template: $TEMPLATE_NAME, instance: $INSTANCE_INFO"

        # Load template configuration from JSON
        TEMPLATE_JSON=$(jq -r --arg name "$TEMPLATE_NAME" '.[$name] // empty' /etc/notification-templates.json)

        if [ -z "$TEMPLATE_JSON" ] || [ "$TEMPLATE_JSON" == "null" ]; then
          echo "[notify] ERROR: Template '$TEMPLATE_NAME' not found or not enabled"
          exit 1
        fi

        # Extract template details
        ENABLED=$(echo "$TEMPLATE_JSON" | jq -r '.enable // false')
        if [ "$ENABLED" != "true" ]; then
          echo "[notify] Template '$TEMPLATE_NAME' is disabled, skipping"
          exit 0
        fi

        PRIORITY=$(echo "$TEMPLATE_JSON" | jq -r '.priority // "normal"')
        TITLE=$(echo "$TEMPLATE_JSON" | jq -r '.title // "Notification"')
        BODY=$(echo "$TEMPLATE_JSON" | jq -r '.body // ""')
        BACKEND=$(echo "$TEMPLATE_JSON" | jq -r '.backend // "${cfg.defaultBackend}"')

        # For OnFailure handlers, extract context from the failed unit
        # INSTANCE_INFO will be the unit name when called with %n (e.g., restic-backups-system.service)
        if [[ "$INSTANCE_INFO" == *.service ]] || [[ "$INSTANCE_INFO" == *.timer ]]; then
          FAILED_UNIT="$INSTANCE_INFO"
          echo "[notify] Detected failed unit: $FAILED_UNIT"

          # Extract last 10 lines of journal for error context
          # Using awk to properly escape newlines for JSON/HTML
          export NOTIFY_ERRORMESSAGE=$(journalctl --no-pager -n 10 -u "$FAILED_UNIT" 2>/dev/null | awk '{printf "%s\\n", $0}' || echo "No log available")

          # Extract job/dataset names from unit name patterns
          # Pattern: restic-backups-JOBNAME.service -> JOBNAME
          if [[ "$FAILED_UNIT" =~ ^restic-backups-(.+)\.service$ ]]; then
            export NOTIFY_JOBNAME="''${BASH_REMATCH[1]}"
            echo "[notify] Extracted job name: $NOTIFY_JOBNAME"

            # Try to extract repository URL from service environment
            REPO_URL=$(systemctl show "$FAILED_UNIT" --property=Environment 2>/dev/null | \
                       grep -oP 'RESTIC_REPOSITORY=\K[^ ]+' || echo "unknown")
            if [ "$REPO_URL" != "unknown" ]; then
              export NOTIFY_REPOSITORY="$REPO_URL"
              echo "[notify] Extracted repository: $NOTIFY_REPOSITORY"
            fi
          fi

          # Pattern: syncoid-DATASET.service -> DATASET (for ZFS replication)
          # Example: syncoid-rpool-safe-home.service -> rpool-safe-home
          if [[ "$FAILED_UNIT" =~ ^syncoid-(.+)\.service$ ]]; then
            export NOTIFY_DATASET="''${BASH_REMATCH[1]}"
            echo "[notify] Extracted dataset: $NOTIFY_DATASET"
          fi

          # Pattern: sanoid.service (no dataset in name, affects all datasets)
          if [[ "$FAILED_UNIT" == "sanoid.service" ]]; then
            export NOTIFY_DATASET="all-datasets"
            echo "[notify] Sanoid failure affects all datasets"
          fi
        fi

        # ---- Resolve placeholder values -------------------------------------
        # Three sources, lowest precedence first:
        #   1. derived   - computed here from the instance and the failed unit
        #   2. static    - modules.notifications.context, for build-time-known
        #                  values a caller cannot supply (e.g. OnFailure hooks,
        #                  which get no chance to run code before firing)
        #   3. runtime   - /run/notify/ctx/<instance>.json, written by callers
        #                  that DO run code first
        #
        # NOTIFY_* variables set above are folded in under their placeholder
        # names: NOTIFY_ERROR_MESSAGE -> errormessage (lowercased, underscores
        # stripped). These are set by this script, in this process, so they
        # actually reach the substitution - unlike an `export` in a caller,
        # which never survives `systemctl start`.
        DERIVED=$(jq -n \
          --arg hostname "${cfg.hostname}" \
          --arg template "$TEMPLATE_NAME" \
          --arg instance "$INSTANCE_INFO" \
          --arg timestamp "$(date -Iseconds)" \
          '{hostname: $hostname, template: $template, instance: $instance, timestamp: $timestamp}')

        if [ -n "$INSTANCE_INFO" ]; then
          DERIVED=$(echo "$DERIVED" | jq -c --arg v "$INSTANCE_INFO" '. + {serviceName: $v}')
        fi

        for var in $(env | grep '^NOTIFY_' | cut -d= -f1 || true); do
          placeholder=$(echo "$var" | sed 's/^NOTIFY_//' | tr '[:upper:]' '[:lower:]' | tr -d '_')
          DERIVED=$(echo "$DERIVED" | jq -c \
            --arg k "$placeholder" --arg v "$(printenv "$var")" '. + {($k): $v}')
        done

        # Only identifier-like keys are usable: substitution is by exact
        # ''${name} match, so anything else could never be referenced anyway.
        SANITIZE='if type == "object" then
                    with_entries(select(.key | test("^[a-zA-Z_][a-zA-Z0-9_]*$")) | .value |= tostring)
                  else {} end'

        STATIC='{}'
        if [ -n "$INSTANCE_INFO" ]; then
          STATIC=$(jq -c --arg u "$INSTANCE_INFO" ".[\$u] // {} | $SANITIZE" \
            /etc/notification-context.json 2>/dev/null || echo '{}')
        fi

        RUNTIME='{}'
        CTX_FILE="/run/notify/ctx/$INSTANCE_STRING.json"
        if [ -f "$CTX_FILE" ]; then
          if PARSED=$(jq -c "$SANITIZE" "$CTX_FILE" 2>/dev/null); then
            RUNTIME="$PARSED"
          else
            echo "[notify] WARNING: $CTX_FILE is not valid JSON; ignoring it" >&2
          fi
          rm -f "$CTX_FILE"
        fi

        VARS=$(jq -n --argjson a "$DERIVED" --argjson b "$STATIC" --argjson c "$RUNTIME" \
          '$a * $b * $c')

        # Every placeholder the template is allowed to use. Anything in this set
        # that did not resolve is rendered as "(unset: name)" - a visibly wrong
        # page beats a silently blank one.
        DECLARED=$(echo "$TEMPLATE_JSON" | jq -c \
          '(.placeholders // []) + ${builtins.toJSON builtinPlaceholders}')

        # Literal substitution, done in jq rather than envsubst. envsubst was
        # the original mechanism and it silently ate any name it could not
        # resolve while leaving dotted names like ''${config.networking.hostName}
        # untouched, which is how a blank service name and a literal Nix
        # expression both reached production.
        render() {
          jq -rn --arg s "$1" --argjson vars "$VARS" --argjson declared "$DECLARED" '
            ($vars | to_entries
             | reduce .[] as $e ($s; gsub("\\$\\{" + $e.key + "\\}"; $e.value)))
            | . as $substituted
            | ($declared | unique
               | reduce .[] as $p ($substituted; gsub("\\$\\{" + $p + "\\}"; "(unset: " + $p + ")")))
          '
        }

        TITLE=$(render "$TITLE")
        BODY=$(render "$BODY")

        echo "[notify] Dispatching to $BACKEND (template: $TEMPLATE_NAME, instance: $INSTANCE_INFO)"

        # ---- Queue the payload ----------------------------------------------
        # The payload carries its own backend. Without that, the only record of
        # where a notification should go was the name of the service that would
        # have been started, so a single drain could not route it.
        PAYLOAD_FILE="/run/notify/$INSTANCE_STRING.json"
        TMP_FILE="$PAYLOAD_FILE.tmp"

        # Written to a temp name and renamed into place: the drain watches
        # *.json, so it can never observe a half-written payload.
        jq -n \
          --arg title "$TITLE" \
          --arg message "$BODY" \
          --arg priority "$PRIORITY" \
          --arg backend "$BACKEND" \
          --arg template "$TEMPLATE_NAME" \
          --arg instance "$INSTANCE_INFO" \
          --arg created "$(date -Iseconds)" \
          '{title: $title, message: $message, priority: $priority,
            backend: $backend, template: $template, instance: $instance, created: $created}' \
          > "$TMP_FILE"

        # Set group ownership to notify-ipc so the drain can read and unlink it
        chgrp notify-ipc "$TMP_FILE"
        mv "$TMP_FILE" "$PAYLOAD_FILE"

        echo "[notify] Payload queued at $PAYLOAD_FILE (backend: $BACKEND)"

        # notify-drain.path watches /run/notify/*.json and will pick this up.
        # A single directory watcher replaces the old per-instance .path units:
        # those had to be declared per caller, but instance names are chosen at
        # failure time (template:%n), so they could never be enumerated at build
        # time. Only 3 of 34 call sites ever had one.
      '';
    };

    # Enable the notification backends based on configuration
    # Individual backend implementations are in their respective modules
  };
}
