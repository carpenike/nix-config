# hosts/forge/services/hermes-agent.nix
#
# Hermes runs natively through its upstream NixOS module. Native mode keeps
# the runtime immutable and applies systemd hardening to every spawned tool;
# upstream container mode intentionally uses a mutable, host-networked runtime.

{ config, inputs, lib, mylib, pkgs, ... }:

let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  serviceName = "hermes-agent";
  stateDir = "/var/lib/hermes";
  dataset = "tank/services/${serviceName}";
  serviceIds = mylib.serviceUids.hermes;
  serviceEnabled = config.services.hermes-agent.enable or false;
  hermesPackage = inputs.hermes-agent.packages.${pkgs.stdenv.hostPlatform.system}.default;
  householdAdvisorPrompt = ''
    You are Household Advisor. Be concise, factual, and family-appropriate.
    You have read-only access to household financial summaries through exactly
    seven Homelab MCP tools: finances_sync_status, finances_monthly_summary,
    finances_recurring, finances_debt_status, finances_breaches,
    finances_buffer, and finances_room. Use them for factual finance questions
    and monitoring. Never state a number unless it appears in current tool
    output; never infer, estimate, or invent values. Measured patterns explicitly
    documented in the finances repository PLAN.md may be cited as context, never
    as authority.
    When an allowlisted member asks "help", "what can you do", "how does this
    work", or similar, do not call any tool. Return this menu in at most 11
    nonblank lines. Wording may be lightly adapted, but preserve every capability
    and limit and do not insert current financial values. The fixed schedule and
    placeholder below are menu text, not tool-derived household values.
    I'm the household finance assistant. What I do:
    📊 Fridays 4pm — the weekly pulse: on-pace status, Amazon, HELOC, anything unusual.
    🔔 Daily quiet check — I only message if something's actually wrong (a feed died, an odd deposit, or buffer below floor).
    You can ask me anytime:
    • "Could we clear the decks today?" / "What's the buffer?"
    • "How much room do we have?" / "Can I spend $X at Costco?"
    • "Did the mortgage, insurance, or another recurring payment go through this month?"
    • "Where's the HELOC at?" / "How's the paydown going?"
    I only report numbers straight from our budget tools — I never guess.
    I can't change or categorize anything; that happens in Ryan's advisor sessions.
    Bigger what-should-we-do questions go to the monthly review.
    For debt, use each debt's accelerate/ride framing and prefer per-debt values
    over total_debt or accelerate_total, which may be transiently high while
    recent card payoffs settle. For recurring history before May 2026, treat a
    CHANGED USAA P&C row as the expected jewelry-only period, not an anomaly.
    For "can I spend $X?" or "how much room?" questions, call finances_room.
    Pass the category when implied; map Costco or groceries to the
    "Groceries & Household" category. Return exactly three newline-separated
    lines with no title, bullets, blank lines, or extra text, and never merge
    template lines. While the spending floor is provisional, use:
    Baseline (floor provisional): <category's typical month>
    Pace: <pace status>
    Verdict: <concrete verdict>
    Otherwise use:
    Pace: <pace status>
    Typical month: <category's typical month>
    Verdict: <concrete verdict>
    When `pace` is `ahead` or `variable_pace_delta` is positive, use exactly
    these three lines instead of the generic template:
    Baseline (floor provisional): <category's typical month; if comparing with
    typical_remaining_pace, add inline that its trailing six-month window has
    one-off-heavy projects/dental and overstates habitual spend until ~November>
    Recovery: <$X over current-month variable glide; target about
    $required_remaining_pace/day for the remaining $days_remaining days,
    $recovery_delta/day tighter than typical, brings the month home>
    Trade: <price the requested spend against that glide and hand the choice
    back; e.g. "puts the glide about $N further over — doable if the remaining
    days absorb it; your call">
    Use only returned fields plus arithmetic on an amount the member supplied.
    If `required_remaining_pace` is negative, report it honestly: the floor is
    already exceeded and even $0/day cannot bring it under; price new spend as
    an additional trade instead of pretending recovery is possible. If citing
    `typical_remaining_pace` or comparing against typical, say its trailing
    six-month window includes one-off-heavy projects/dental and overstates
    habitual spend until those months roll out around November. Never add a
    fourth or standalone context line: optional PLAN.md context such as "Costco
    is usually ~4 trips/mo, median $219" may appear only within the Baseline
    line and never replace required template content. Never forbid, moralize,
    or reference overages before the current month. Be a supportive scoreboard,
    never a gatekeeper.
    Never provide investment advice. For financial questions beyond simple
    facts, say: "bring it to the monthly review."
  '';
  nonFinanceGatewayPrompt = ''
    Keep your existing non-finance duties. Household finance lives in the
    family Signal group and must never be retrieved or discussed here. For any
    finance question, do not call tools or try to obtain financial data through
    terminal commands, files, memory, web access, or another indirect path.
    Reply politely: "Finance lives in our Signal group." Do not include any
    household financial details or numbers.
  '';
  # Human gate cleared 2026-07-31: Signal group membership and the private
  # spending floor are confirmed. This resumes the existing seeded job.
  weeklyPulseEnabled = true;
  weeklyPulseJobName = "weekly-household-pulse";
  weeklyPulsePrompt = ''
    Compose the weekly household finance pulse from live data at run time.
    Call exactly finances_sync_status, finances_monthly_summary,
    finances_recurring, finances_debt_status, and finances_room. Never use
    signal_send; native cron delivery sends your final response. Never cache the
    spending floor or Amazon baseline, and never state a number absent from
    current tool output.

    Return exactly five newline-separated lines with no title, preamble, or
    follow-up:
    1. Data health. If any account is stale by more than three days, make that
       warning the headline; otherwise say all accounts are fresh.
     2. Month-to-date spend versus the pro-rated floor. On pace, keep the existing
       direction and amount. Over pace, use one recovery sentence, never a bare
       verdict: "$X over — target about $required_remaining_pace/day for the
       remaining $days_remaining days, about $recovery_delta/day tighter than
       the one-off-heavy trailing typical, brings the month home." If required
       pace is negative, report that the floor is already exceeded and price
       further spend as a trade; never claim $0/day can recover it.
    3. Amazon spend for the returned seven-day window and month to date versus
       the returned monthly baseline.
    4. HELOC balance and the returned change since the prior comparison. Always
       show the delta and briefly celebrate a paydown.
    5. Missing/changed recurring payments and new payees over the returned
       threshold; if none, say "all recurring paid; nothing unusual."

    Be a scoreboard, not a referee: concise facts and deltas, no blame or advice.
    Celebrate on-track spending and paydowns. If detail will not fit, flag it for
    the monthly review rather than adding a sixth line.
  '';
  dailySentinelJobName = "daily-finance-sentinel";
  dailySentinelSchedule = "0 8 * * *";
  dailySentinelPrompt = ''
    Act as a silent household-finance sentinel. Call exactly these three tools,
    once each, using live data at run time:
    - finances_sync_status with trigger_sync=false
    - finances_breaches with lookback_days=3
    - finances_buffer with no arguments

    Send an alert only when at least one of these predicates is true:
    1. `breach_candidates` is non-empty.
    2. A non-manual sync account has status `dead`. For basis `feed`, require
      feed_age_hours > 72. For basis `activity_fallback`, trust `dead` as the
      cadence-aware fallback and identify that weaker basis. Ignore `stale`,
      `quiet_but_healthy`, and manual accounts.
    3. Buffer floor is configured and buffer status is `below_floor`. A status
      of `no_floor`, `near_floor`, or `above_floor` is not an alert.
    4. Revolving creep is armed only when the tool's `as_of` date is more than
      25 calendar days after the 2026-07-30 card-payoff baseline (never on or
      before 2026-08-24). Then alert for each `components.card_accounts` row
      where `counted` is true and the owed balance exceeds $500 (`balance` is
      less than -500).

    After all three calls, privately reduce the results to four booleans named
    BREACH, DEAD_FEED, BELOW_FLOOR, and REVOLVING_CREEP using only the rules
    above. Do not print this checklist or mention any false category.

    Final-response gate:
    - If all four booleans are false, your entire final response MUST be exactly
      `[SILENT]`. Do not explain the healthy state, list non-events, summarize
      the calls, or mention why the response is silent. Hermes suppresses that
      marker and writes the silent-run log line.
    - Otherwise, return only one terse factual line for each true boolean. Do
      not include lines for false booleans, routine status, advice, blame, or
      invented values.

    Never use signal_send; native cron delivery sends the final response.
  '';
  hermesCli = pkgs.writeShellScriptBin "hermes" ''
    export HOME="${stateDir}"
    export HERMES_HOME="${stateDir}/.hermes"
    cd "${stateDir}/workspace"
    exec ${hermesPackage}/bin/hermes "$@"
  '';
  weeklyPulsePromptFile = pkgs.writeText "hermes-weekly-pulse-prompt" weeklyPulsePrompt;
  dailySentinelPromptFile = pkgs.writeText "hermes-daily-finance-sentinel-prompt" dailySentinelPrompt;
  weeklyPulseSeedScript = pkgs.writeShellScript "hermes-weekly-pulse-seed" ''
    set -euo pipefail

    job_name=${lib.escapeShellArg weeklyPulseJobName}
    prompt="$(${pkgs.coreutils}/bin/cat ${weeklyPulsePromptFile})"
    signal_group_id="$SIGNAL_GROUP_ALLOWED_USERS"
    if [[ -z "$signal_group_id" ]]; then
      echo "hermes weekly pulse: SIGNAL_GROUP_ALLOWED_USERS is empty" >&2
      exit 1
    fi
    case "$signal_group_id" in
      group.*)
        echo "hermes weekly pulse: expected raw Signal group ID, not REST send target" >&2
        exit 1
        ;;
    esac

    list_jobs() {
      ${hermesCli}/bin/hermes cron list --all
    }
    job_count() {
      ${pkgs.gnugrep}/bin/grep -Fc "Name:      $job_name" <<<"$1" || true
    }
    job_block() {
      ${pkgs.gawk}/bin/awk -v needle="Name:      $job_name" \
        'BEGIN { RS = "" } index($0, needle) { print; exit }' <<<"$1"
    }

    jobs="$(list_jobs)"
    count="$(job_count "$jobs")"
    if [[ "$count" -eq 0 ]]; then
      # New jobs start local-only and are paused before the real schedule and
      # Signal target are installed. There is no first-deploy delivery window.
      ${hermesCli}/bin/hermes cron create "0 16 * * 5" "$prompt" \
        --name "$job_name" \
        --deliver local \
        --repeat 0 >/dev/null
    elif [[ "$count" -ne 1 ]]; then
      echo "hermes weekly pulse: expected one '$job_name' job, found $count" >&2
      exit 1
    fi

    # Hermes currently prints lifecycle failures but exits zero. Verify every
    # security-sensitive transition from persisted list output instead.
    ${hermesCli}/bin/hermes cron pause "$job_name" >/dev/null
    jobs="$(list_jobs)"
    block="$(job_block "$jobs")"
    if [[ "$(job_count "$jobs")" -ne 1 ]] || ! ${pkgs.gnugrep}/bin/grep -Fq "[paused]" <<<"$block"; then
      echo "hermes weekly pulse: failed to establish paused pre-edit state" >&2
      exit 1
    fi

    ${hermesCli}/bin/hermes cron edit "$job_name" \
      --schedule "0 16 * * 5" \
      --prompt "$prompt" \
      --name "$job_name" \
      --deliver "signal:group:$signal_group_id" \
      --repeat 0 \
      --clear-skills >/dev/null

    if ${lib.boolToString weeklyPulseEnabled}; then
      ${hermesCli}/bin/hermes cron resume "$job_name" >/dev/null
      expected_status="[active]"
    else
      ${hermesCli}/bin/hermes cron pause "$job_name" >/dev/null
      expected_status="[paused]"
    fi

    jobs="$(list_jobs)"
    block="$(job_block "$jobs")"
    if [[ "$(job_count "$jobs")" -ne 1 ]] \
      || ! ${pkgs.gnugrep}/bin/grep -Fq "$expected_status" <<<"$block" \
      || ! ${pkgs.gnugrep}/bin/grep -Fq "Schedule:  0 16 * * 5" <<<"$block" \
      || ! ${pkgs.gnugrep}/bin/grep -Fq "Repeat:    ∞" <<<"$block" \
      || ! ${pkgs.gnugrep}/bin/grep -Fq "Deliver:   signal:group:$signal_group_id" <<<"$block"; then
      echo "hermes weekly pulse: persisted job failed final postconditions" >&2
      exit 1
    fi
  '';
  dailySentinelSeedScript = pkgs.writeShellScript "hermes-daily-finance-sentinel-seed" ''
    set -euo pipefail

    job_name=${lib.escapeShellArg dailySentinelJobName}
    schedule=${lib.escapeShellArg dailySentinelSchedule}
    prompt="$(${pkgs.coreutils}/bin/cat ${dailySentinelPromptFile})"
    signal_group_id="$SIGNAL_GROUP_ALLOWED_USERS"
    if [[ -z "$signal_group_id" ]]; then
      echo "hermes finance sentinel: SIGNAL_GROUP_ALLOWED_USERS is empty" >&2
      exit 1
    fi
    case "$signal_group_id" in
      group.*)
        echo "hermes finance sentinel: expected raw Signal group ID, not REST send target" >&2
        exit 1
        ;;
    esac

    list_jobs() {
      ${hermesCli}/bin/hermes cron list --all
    }
    job_count() {
      ${pkgs.gnugrep}/bin/grep -Fc "Name:      $job_name" <<<"$1" || true
    }
    job_block() {
      ${pkgs.gawk}/bin/awk -v needle="Name:      $job_name" \
        'BEGIN { RS = "" } index($0, needle) { print; exit }' <<<"$1"
    }

    jobs="$(list_jobs)"
    count="$(job_count "$jobs")"
    if [[ "$count" -eq 0 ]]; then
      ${hermesCli}/bin/hermes cron create "$schedule" "$prompt" \
        --name "$job_name" \
        --deliver local \
        --repeat 0 >/dev/null
    elif [[ "$count" -ne 1 ]]; then
      echo "hermes finance sentinel: expected one '$job_name' job, found $count" >&2
      exit 1
    fi

    ${hermesCli}/bin/hermes cron pause "$job_name" >/dev/null
    jobs="$(list_jobs)"
    block="$(job_block "$jobs")"
    if [[ "$(job_count "$jobs")" -ne 1 ]] || ! ${pkgs.gnugrep}/bin/grep -Fq "[paused]" <<<"$block"; then
      echo "hermes finance sentinel: failed to establish paused pre-edit state" >&2
      exit 1
    fi

    ${hermesCli}/bin/hermes cron edit "$job_name" \
      --schedule "$schedule" \
      --prompt "$prompt" \
      --name "$job_name" \
      --deliver "signal:group:$signal_group_id" \
      --repeat 0 \
      --clear-skills >/dev/null
    ${hermesCli}/bin/hermes cron resume "$job_name" >/dev/null

    jobs="$(list_jobs)"
    block="$(job_block "$jobs")"
    if [[ "$(job_count "$jobs")" -ne 1 ]] \
      || ! ${pkgs.gnugrep}/bin/grep -Fq "[active]" <<<"$block" \
      || ! ${pkgs.gnugrep}/bin/grep -Fq "Schedule:  $schedule" <<<"$block" \
      || ! ${pkgs.gnugrep}/bin/grep -Fq "Repeat:    ∞" <<<"$block" \
      || ! ${pkgs.gnugrep}/bin/grep -Fq "Deliver:   signal:group:$signal_group_id" <<<"$block"; then
      echo "hermes finance sentinel: persisted job failed final postconditions" >&2
      exit 1
    fi
  '';
  weeklyPulseDryRunScript = pkgs.writeShellScript "hermes-weekly-pulse-dry-run" ''
    set -euo pipefail

    export HOME="${stateDir}"
    export HERMES_HOME="${stateDir}/.hermes"
    job_name="${weeklyPulseJobName}-dry-run"
    prompt="$(${pkgs.coreutils}/bin/cat ${weeklyPulsePromptFile})"
    ${hermesCli}/bin/hermes cron remove "$job_name" >/dev/null 2>&1 || true

    create_output="$(${hermesCli}/bin/hermes cron create "1d" "$prompt" \
      --name "$job_name" \
      --deliver local)"
    job_id="$(${pkgs.gnugrep}/bin/grep -Eo '[0-9a-f]{12}' <<<"$create_output" | ${pkgs.coreutils}/bin/head -n 1)"
    if [[ -z "$job_id" ]]; then
      printf '%s\n' "$create_output" >&2
      echo "hermes weekly pulse dry run: could not determine job ID" >&2
      exit 1
    fi

    ${hermesCli}/bin/hermes cron run "$job_id"
    output_dir="$HERMES_HOME/cron/output/$job_id"
    for ((attempt = 0; attempt < 300; attempt++)); do
      for output in "$output_dir"/*.md; do
        if [[ -f "$output" ]]; then
          if ${pkgs.gnugrep}/bin/grep -Fq "## Error" "$output"; then
            ${pkgs.coreutils}/bin/cat "$output" >&2
            ${hermesCli}/bin/hermes cron remove "$job_id" >/dev/null
            exit 1
          fi
          ${pkgs.coreutils}/bin/cat "$output"
          ${hermesCli}/bin/hermes cron remove "$job_id" >/dev/null
          exit 0
        fi
      done
      ${pkgs.coreutils}/bin/sleep 2
    done

    echo "hermes weekly pulse dry run: timed out; local job remains $job_id" >&2
    exit 1
  '';
  pulseServiceHardening = {
    User = "hermes";
    Group = "hermes";
    NoNewPrivileges = true;
    PrivateTmp = true;
    PrivateDevices = true;
    PrivateNetwork = true;
    ProtectSystem = "strict";
    ProtectHome = true;
    ReadWritePaths = [ stateDir ];
    ProtectClock = true;
    ProtectControlGroups = true;
    ProtectKernelLogs = true;
    ProtectKernelModules = true;
    ProtectKernelTunables = true;
    RestrictAddressFamilies = [ "AF_UNIX" ];
    RestrictSUIDSGID = true;
    LockPersonality = true;
    RestrictRealtime = true;
    SystemCallArchitectures = "native";
    CapabilityBoundingSet = "";
    AmbientCapabilities = "";
    UMask = "0077";
  };
in
{
  imports = [
    inputs.hermes-agent.nixosModules.default
  ];

  config = lib.mkMerge [
    {
      services.hermes-agent = {
        enable = true;
        package = hermesPackage;

        user = "hermes";
        group = "hermes";
        createUser = false;
        inherit stateDir;
        workingDirectory = "${stateDir}/workspace";

        # A small wrapper below exposes the managed CLI without merging the
        # upstream package's unstable propagated tools into the system profile.
        addToSystemPackages = false;
        environmentFiles = [
          config.sops.templates."hermes-agent-env".path
          config.sops.secrets."hermes-agent/signal-env".path
        ];
        environment = {
          API_SERVER_ENABLED = "false";
          # Telegram numeric IDs are stable and non-secret. Keep the env
          # allowlist as defense in depth alongside the platform policy below.
          TELEGRAM_ALLOWED_USERS = "8903896206";
        };

        # Hermes v0.19 scopes MCP servers per platform by server alias, not by
        # individual tool. Keep finance and general-purpose tools on separate
        # aliases even though they share an endpoint and bounded OAuth scope.
        mcpServers.holthome = {
          url = "https://mcp.${config.networking.domain}/mcp";
          auth = "oauth";
          connect_timeout = 60;
          timeout = 120;
          tools.include = [
            "finances_sync_status"
            "finances_monthly_summary"
            "finances_recurring"
            "finances_debt_status"
            "finances_breaches"
            "finances_buffer"
            "finances_room"
          ];
          sampling.enabled = false;
        };

        # Proof capability for non-finance Homelab access from Telegram. Add
        # future Telegram tools explicitly; never add a finances_* tool here.
        mcpServers."holthome-telegram" = {
          url = "https://mcp.${config.networking.domain}/mcp";
          auth = "oauth";
          connect_timeout = 60;
          timeout = 120;
          tools.include = [ "homelab_list_status" ];
          sampling.enabled = false;
        };

        settings = {
          _config_version = 33;
          cron.wrap_response = false;
          # The typed mcpServers option owns transport/tool policy; this
          # freeform map adds fork-supported confidential OAuth fields that
          # are not yet exposed by the upstream NixOS submodule.
          mcp_servers.holthome.oauth = {
            client_id = "d2vzX8u-_LxxkAJFlKw4TglIWAnvV8zc";
            client_secret = "\${HOMELAB_MCP_OAUTH_CLIENT_SECRET}";
            scope = "hermes";
            redirect_port = 8765;
            redirect_uri = "http://127.0.0.1:8765/callback";
          };
          mcp_servers."holthome-telegram".oauth = {
            client_id = "d2vzX8u-_LxxkAJFlKw4TglIWAnvV8zc";
            client_secret = "\${HOMELAB_MCP_OAUTH_CLIENT_SECRET}";
            scope = "hermes";
            redirect_port = 8765;
            redirect_uri = "http://127.0.0.1:8765/callback";
          };
          model.default = "anthropic/claude-sonnet-4";
          timezone = config.time.timeZone;
          platform_toolsets = {
            cron = [ "safe" "holthome" ];
            signal = [ "hermes-signal" "holthome" ];
            # Listing one MCP alias makes this an allowlist; the finance alias
            # is absent from Telegram's tool catalog and tool_call bridge.
            telegram = [ "hermes-telegram" "holthome-telegram" ];
          };
          gateway.platforms.telegram = {
            enabled = true;
            dm_policy = "allowlist";
            allow_from = [ "8903896206" ];
            # A user's private Telegram chat ID equals their numeric user ID.
            allowed_chats = [ "8903896206" ];
            group_policy = "disabled";
            channel_overrides."8903896206".system_prompt = nonFinanceGatewayPrompt;
          };
          gateway.platforms.signal = {
            enabled = true;
            # SIGNAL_ALLOWED_USERS is mirrored into the SOPS env. An explicit
            # allowlist makes unauthorized DMs silent instead of issuing
            # pairing codes; group intake is separately restricted by
            # SIGNAL_GROUP_ALLOWED_USERS.
            channel_overrides."+12406206585".system_prompt = householdAdvisorPrompt;
          };
          terminal = {
            backend = "local";
            timeout = 180;
          };
          tool_loop_guardrails = {
            hard_stop_enabled = true;
            hard_stop_after = {
              exact_failure = 5;
              idempotent_no_progress = 5;
            };
          };
        };

        restartSec = 10;
      };

      environment.systemPackages = [ hermesCli ];

      users.groups.hermes.gid = serviceIds.gid;
      users.users.hermes = {
        uid = serviceIds.uid;
        isSystemUser = true;
        group = "hermes";
        description = serviceIds.description;
        home = stateDir;
        createHome = true;
        shell = pkgs.bashInteractive;
        extraGroups = serviceIds.extraGroups;
      };

      # Repair ownership from the initial deployment, which briefly used a UID
      # already assigned to nscd. The mode field is "-" to preserve restrictive
      # runtime file permissions while recursively fixing only owner/group.
      systemd.tmpfiles.rules = [
        "Z ${stateDir} - hermes hermes -"
      ];
    }

    (lib.mkIf serviceEnabled {
      modules.storage.datasets.services.${serviceName} = {
        mountpoint = stateDir;
        recordsize = "16K";
        compression = "zstd";
        properties = {
          atime = "off";
          "com.sun:auto-snapshot" = "true";
        };
        owner = "hermes";
        group = "hermes";
        mode = "0750";
      };

      modules.backup.sanoid.datasets.${dataset} =
        forgeDefaults.mkSanoidDataset serviceName;

      modules.services.backup.restic.jobs.${serviceName} = {
        enable = true;
        repository = forgeDefaults.backup.repository;
        paths = [ stateDir ];
        tags = [ serviceName "ai" "forge" ];
        frequency = "daily";
        useSnapshots = true;
        zfsDataset = dataset;
      };

      modules.alerting.rules."${serviceName}-service-down" =
        forgeDefaults.mkSystemdServiceDownAlert
          serviceName
          "Hermes Agent"
          "AI agent gateway";

      # The upstream native unit already uses NoNewPrivileges,
      # ProtectSystem=strict, PrivateTmp, and a dedicated user. Tighten the
      # remaining host boundary and cap runaway agent resource consumption.
      systemd.services.hermes-agent = {
        # Keep Hermes running across signal-api restarts so its WebSocket loop
        # can reconnect with the adapter's jittered 2s -> 60s backoff.
        after = [ "podman-signal-api.service" ];
        wants = [ "podman-signal-api.service" ];

        # Hermes expands env references only in YAML values, not mapping keys.
        # Render the SOPS-held group ID into the exact Signal chat key before
        # startup, then wait for the REST API so the initial connect is not
        # lost while the json-rpc daemon is still warming up.
        preStart = ''
          signalGroupId="$(${pkgs.gawk}/bin/awk -F= '
            $1 == "SIGNAL_GROUP_ALLOWED_USERS" {
              sub(/^[^=]*=/, "")
              value = $0
            }
            END {
              if (value == "") exit 1
              print value
            }
          ' "${stateDir}/.hermes/.env")"

          case "$signalGroupId" in
            group.*)
              echo "hermes-agent: Signal inbound group ID must not include the REST send prefix" >&2
              exit 1
              ;;
            ?*) ;;
            *)
              echo "hermes-agent: Signal inbound group ID is missing" >&2
              exit 1
              ;;
          esac

          SIGNAL_GROUP_CHAT_ID="group:$signalGroupId" \
          HOUSEHOLD_ADVISOR_PROMPT="$(${pkgs.coreutils}/bin/cat ${pkgs.writeText "household-advisor-prompt" householdAdvisorPrompt})" \
            ${pkgs.yq-go}/bin/yq --inplace \
              '.gateway.platforms.signal.channel_overrides |= with_entries(select(.key | test("^group:") | not)) |
               .gateway.platforms.signal.channel_overrides[strenv(SIGNAL_GROUP_CHAT_ID)].system_prompt = strenv(HOUSEHOLD_ADVISOR_PROMPT)' \
              "${stateDir}/.hermes/config.yaml"

          ${pkgs.curl}/bin/curl --fail --silent --show-error \
            --retry 30 --retry-all-errors --retry-delay 2 \
            --connect-timeout 2 --max-time 5 \
            "http://127.0.0.1:${toString config.modules.services.signal-api.port}/v1/health" \
            --output /dev/null
        '';

        # Upstream merges config.yaml during activation, outside the unit, so
        # settings changes otherwise leave the running gateway on stale config.
        restartTriggers = [
          (pkgs.writeText "hermes-agent-settings" (builtins.toJSON config.services.hermes-agent.settings))
        ];

        serviceConfig = {
          ProtectHome = lib.mkForce true;
          PrivateDevices = true;
          ProtectClock = true;
          ProtectControlGroups = true;
          ProtectKernelLogs = true;
          ProtectKernelModules = true;
          ProtectKernelTunables = true;
          RestrictSUIDSGID = true;
          LockPersonality = true;
          RestrictRealtime = true;
          SystemCallArchitectures = "native";
          CapabilityBoundingSet = "";
          AmbientCapabilities = "";
          UMask = lib.mkForce "0077";
          MemoryHigh = "3G";
          MemoryMax = "4G";
          CPUQuota = "200%";
          TasksMax = 512;
        };
      };

      systemd.services.hermes-agent-weekly-pulse-seed = {
        description = "Seed the gated Hermes weekly household pulse";
        after = [ "hermes-agent.service" ];
        requires = [ "hermes-agent.service" ];
        wantedBy = [ "multi-user.target" ];
        restartTriggers = [ weeklyPulsePromptFile ];
        serviceConfig = pulseServiceHardening // {
          Type = "oneshot";
          RemainAfterExit = true;
          EnvironmentFile = [ config.sops.secrets."hermes-agent/signal-env".path ];
          ExecStart = weeklyPulseSeedScript;
        };
      };

      systemd.services.hermes-agent-daily-finance-sentinel-seed = {
        description = "Seed the Hermes daily finance sentinel";
        after = [ "hermes-agent.service" ];
        requires = [ "hermes-agent.service" ];
        wantedBy = [ "multi-user.target" ];
        restartTriggers = [ dailySentinelPromptFile ];
        serviceConfig = pulseServiceHardening // {
          Type = "oneshot";
          RemainAfterExit = true;
          EnvironmentFile = [ config.sops.secrets."hermes-agent/signal-env".path ];
          ExecStart = dailySentinelSeedScript;
        };
      };

      # Manual acceptance path: `systemctl start
      # hermes-agent-weekly-pulse-dry-run.service`. The temporary job always
      # uses local delivery; this unit prints its saved result to the journal.
      systemd.services.hermes-agent-weekly-pulse-dry-run = {
        description = "Compose a local-only Hermes weekly household pulse";
        after = [ "hermes-agent.service" ];
        requires = [ "hermes-agent.service" ];
        serviceConfig = pulseServiceHardening // {
          Type = "oneshot";
          PrivateNetwork = false;
          RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
          ExecStart = weeklyPulseDryRunScript;
          TimeoutStartSec = "11min";
        };
      };
    })
  ];
}
