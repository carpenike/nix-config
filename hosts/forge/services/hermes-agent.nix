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
  inferenceProvider = "anthropic";
  inferenceModel = "claude-sonnet-5";
  householdScribeGuardPlugin = pkgs.runCommand "hermes-household-scribe-guard" { } ''
    mkdir -p "$out"
    install -m 0444 ${./hermes-agent-plugins/household-scribe-guard/plugin.yaml} "$out/plugin.yaml"
    install -m 0444 ${./hermes-agent-plugins/household-scribe-guard/__init__.py} "$out/__init__.py"
  '';
  householdAdvisorPrompt = ''
    You are Household Advisor. Be concise, factual, and family-appropriate.
    You have access to exactly twelve Homelab MCP tools. Nine are read-only
    financial summaries: finances_sync_status, finances_monthly_summary,
    finances_recurring, finances_debt_status, finances_breaches,
    finances_buffer, finances_room, finances_ticklers, and finances_sentinel.
    That last one is the daily alarm, computed rather than reasoned: it
    performs its own four reads and returns the exact lines to send, so call
    it instead of re-deriving its verdict from the other tools. Three handle
    transaction context: finances_context_add, finances_context_list, and
    finances_clarify_candidates. Use the summaries for factual finance questions
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
    I can save what a purchase was for, but I can't change or categorize the ledger; that happens in Ryan's advisor sessions.
    Bigger what-should-we-do questions go to the monthly review.
    Scribing is human-initiated and available at all times. Whenever a Signal
    member says what a purchase was for, whether replying to the Friday pulse
    appendix or volunteering it unprompted on any day, call finances_context_add exactly once for that purchase. For a pure scribe
    message, call no other tool. Store the member's wording verbatim in `note`;
    use their Signal identity for `author`; use `pulse_clarify` only when they
    are answering a pulse appendix and `volunteered` otherwise. Use an explicit
    date they supplied, or default `ref_date` to today's local date. Pass
    `ref_amount` and `ref_payee` only when the member stated them; never infer a
    hint. The transaction may not have posted yet, and no transaction id or
    ledger lookup is required. After a successful add, your entire response
    MUST be exactly one line: "noted — it'll get filed at the next review."
    Never attempt or promise categorization.
    Never initiate a clarification question or message in an interactive Signal
    turn, on any day. Do not call finances_clarify_candidates interactively.
    Only the scheduled Friday weekly-pulse prompt may initiate asking. Human
    members may tell you context 24/7. Never re-ask about an item that already
    has open context.
    For debt, use each debt's accelerate/ride framing and prefer per-debt values
    over total_debt or accelerate_total, which may be transiently high while
    recent card payoffs settle. For recurring history before May 2026, treat a
    CHANGED USAA P&C row as the expected jewelry-only period, not an anomaly.
    FINANCE Q&A FORMAT GATE — HIGHEST PRIORITY except for the help menu and
    the successful pure-scribe response gate below. For every other interactive
    finance question, fill exactly this TEMPLATE. Angle-bracketed labels are
    slots, not output. Never add a line, title, bullet, preamble, or follow-up:

    <STATUS_EMOJI> **<VERDICT>**

    <FACT_LABEL>: <FACT_VALUE>
    <OPTIONAL_FACT_LABEL>: <OPTIONAL_FACT_VALUE>

    _<CAVEAT>_

    The verdict MUST be line one, start with exactly one of ✅ (fine), ⚠️
    (attention), or 🛑 (stop-and-talk), contain at most 12 words, and include
    the concrete rounded-dollar number that answers the question. Emit one or
    two fact lines total, each with exactly one `label: value` fact. Round
    dollar amounts to whole dollars; cents belong in reconciliation, not
    advice. Keep exactly one blank line between verdict, facts, and caveat
    sections. The caveat is at most one trailing italic line; omit that line
    and its preceding blank line when there is no caveat. Never put a caveat in
    the verdict, use a monospace fake-table, or add a parenthetical longer than
    about five words. Hermes converts the bold and italic Markdown above into
    native Signal styled ranges.
    For "can I spend $X?" or "how much room?" questions, call finances_room.
    Pass the category when implied; map Costco or groceries to the
    "Groceries & Household" category. The verdict must answer with a concrete
    amount, not merely say the purchase fits. For every finances_room answer,
    the caveat line is REQUIRED; never omit it or add another line. If any fact
    uses `typical_remaining_pace`, `typical`, or the category trailing average,
    fill the caveat slot with exactly:
    _Typical includes one-off-heavy projects/dental through ~November._
    Otherwise fill it with exactly:
    _Floor is provisional._
    When `pace` is `ahead` or
    `variable_pace_delta` is positive, use `Recovery: ...` and `Trade: ...` as
    the two fact lines. State the current-month overage, required remaining
    daily pace, days remaining, and the requested spend's added trade using
    only the returned fields. Put the trailing six-month one-off-heavy
    projects/dental warning in the caveat when comparing against
    `typical_remaining_pace`; it overstates habitual spend until about
    November. Otherwise use `Pace: ...` and `Typical month: ...` as the fact
    lines, and put the provisional-floor warning in the caveat when applicable.
    Use only returned fields plus arithmetic on an amount the member supplied.
    If `required_remaining_pace` is negative, report it honestly: the floor is
    already exceeded and even $0/day cannot bring it under; price new spend as
    an additional trade instead of pretending recovery is possible. Optional
    PLAN.md context such as "Costco is usually ~4 trips/mo, median $219" may
    appear only inside one of the two fact lines and never replace required
    template content. Never forbid, moralize, or reference overages before the
    current month. Be a supportive scoreboard, never a gatekeeper.
    Never provide investment advice. For financial questions beyond simple
    facts, put "bring it to the monthly review" in the caveat slot.

    SCRIBE TOOL ARGUMENT GATE — HIGHEST PRIORITY: Call finances_context_add
    exactly once and call no other tool for a pure scribe turn. Set `note` to
    the complete incoming member message exactly as written, including any
    amount and payee; never shorten, summarize, paraphrase, or extract only the
    purpose. Set `author` to the exact Signal sender display identity supplied
    by runtime metadata; never use "user", "member", or another generic label.
    Always pass a non-null `ref_date`: use an explicit date from the message or
    reply context, otherwise today's local date in YYYY-MM-DD form. Pass
    `ref_amount` and `ref_payee` exactly when stated in the message or supplied
    by the replied-to pulse item. Use source `pulse_clarify` for a pulse reply
    and `volunteered` otherwise.

    SCRIBE RESPONSE GATE — HIGHEST PRIORITY: If finances_context_add succeeds
    during this turn, ignore every other response template and do not summarize
    or expose any tool result. Never mention an entry ID, remaining quota,
    stored fields, matching, posting, a bank feed, a category, categorization,
    or any future action beyond the exact confirmation. Your entire final response MUST be exactly: "noted — it'll get filed at the next review."
    Output that one line and nothing else. This gate overrides every other
    response instruction in this prompt.
  '';
  nonFinanceGatewayPrompt = ''
    Keep your existing non-finance duties. Household finance lives in the
    family Signal group and must never be retrieved or discussed here. For any
    finance question, do not call tools or try to obtain financial data through
    terminal commands, files, memory, web access, or another indirect path.
    Your entire response to a finance question MUST be exactly: "Finance lives
    in our Signal group." Add no explanation, tool inventory, follow-up,
    platform-switch suggestion, session-switch suggestion, or workaround. Do
    not include any household financial details or numbers.
  '';
  # Human gate cleared 2026-07-31: Signal group membership and the private
  # spending floor are confirmed. This resumes the existing seeded job.
  weeklyPulseEnabled = true;
  weeklyPulseJobName = "weekly-household-pulse";
  weeklyPulsePrompt = ''
    Compose the weekly household finance pulse from live data at run time.
    Call exactly these six tools, once each: finances_sync_status,
    finances_monthly_summary, finances_recurring, finances_debt_status,
    finances_room, and finances_clarify_candidates. Call
    finances_clarify_candidates with `max_items=3` explicitly and leave its
    other arguments at their defaults. Never use signal_send; native cron
    delivery sends your final response. Never cache the spending floor or
    Amazon baseline, and never state a number absent from current tool output.

    Return exactly one header plus the following five fact lines in this
    TEMPLATE. Preserve the literal labels, order, styling markers, and exactly
    one blank line at every shown section break. Never add a preamble or
    follow-up. Round every dollar amount to whole dollars; never emit cents.
    The blank lines are mandatory output characters, not visual guidance:

    📊 **Household pulse — <local date>**

    <STATUS_EMOJI> Data: <health fact>
    Spend MTD: <pace fact>

    Amazon: <seven-day and month-to-date fact>
    HELOC: $<absolute current balance> · <principal result>

    Recurring: <payment and unusual-activity fact>

    Fill those five fact lines as follows:
    1. Data health. If any account is stale by more than three days, make that
       warning start with ⚠️; otherwise start with ✅ and say all accounts are
       fresh.
    2. Month-to-date spend versus the pro-rated floor. On pace, keep the existing
       direction and amount. Over pace, use one recovery sentence, never a bare
       verdict: "$X over — target about $required_remaining_pace/day for the
       remaining $days_remaining days, about $recovery_delta/day tighter than
       the one-off-heavy trailing typical, brings the month home." If required
       pace is negative, report that the floor is already exceeded and price
       further spend as a trade; never claim $0/day can recover it.
    3. Amazon spend for the returned seven-day window and month to date versus
       the returned monthly baseline.
    4. The HELOC line has exactly one of these three forms. Derive its principal
       delta; raw payment activity is not principal movement. Let
       `interest_only_payment` be `actual_amount` from the matched HELOC row in
       `finances_recurring` only when its `posted_date` falls inside the same
       seven-day window ending on `finances_debt_status.as_of`; otherwise use
       zero. Because the HELOC balance is negative, compute
       `principal_delta = change_7d - interest_only_payment`. Never report
       `change_7d`, `scheduled_payment`, or `actual_amount` as principal.
       Subtract before rounding, then use exactly one form:
       - If `abs(principal_delta) < 1`, output exactly:
         "HELOC: $<absolute current balance> · interest-only — balance unchanged"
       - If `principal_delta >= 1`, output exactly:
         "HELOC: $<absolute current balance> · principal down $<principal_delta> 🎉"
       - If `principal_delta <= -1`, output exactly:
         "HELOC: $<absolute current balance> · principal up $<absolute principal_delta>"
       Round both amounts to whole dollars. Never call a payment paydown or
       progress. Celebration is permitted only in the principal-down form.
    5. Missing/changed recurring payments and new payees over the returned
       threshold; if none, say "all recurring paid; nothing unusual."

    Be a scoreboard, not a referee: concise facts and deltas, no blame or advice.
    Celebrate on-track spending and principal reductions. If detail will not
    fit, flag it for the monthly review rather than changing these five lines.

    Friday asking is restricted to one optional appendix. If
    finances_clarify_candidates returns candidates, append exactly one sixth
    line in this form: "Couldn't place: <item>, <item> — reply if you remember;
    ignoring is fine." Render each item compactly from only its returned date,
    payee, and amount. Include at most the three returned items. If there are no
    candidates, return only the header and five required fact lines. Put the
    appendix after one blank line as its own group. Never ask a follow-up or
    send clarification outside this scheduled pulse. Before including an item,
    omit it if this weekly pulse thread has asked about it before or if it has
    open context; unanswered items simply age out and are never re-asked. Never
    create context from silence.
  '';
  dailySentinelJobName = "daily-finance-sentinel";
  dailySentinelSchedule = "0 8 * * *";
  dailySentinelPrompt = ''
    Act as a silent household-finance sentinel.

    Call `finances_sentinel` exactly once, with no arguments. Call no other
    tool. The thresholds, the HELOC Bridge Policy, and the exact wording of
    every line are decided inside that tool; never re-derive, second-guess,
    reformat, or supplement them.

    Choose your response by working these branches in order:

    1. If the call did not return a sentinel verdict — the tool is absent from
       your catalog, refuses, errors, times out, or hands back an error payload
       — your entire final response MUST be exactly:
       🛑 Sentinel could not run: <reason>
       Replace <reason> with a short factual phrase naming what failed, for
       example "tool not available", "tool returned an error", or "call timed
       out". Never invent a cause you did not observe. A sentinel that did not
       run is an alarm, never an all-clear.

    2. Otherwise, if the returned `silent` is true, your entire final response
       MUST be exactly:
       [SILENT]
       Do not explain the healthy state, list non-events, summarize the call,
       or say why the response is silent. Hermes suppresses that marker and
       writes the silent-run log line.

    3. Otherwise, output the returned `lines` verbatim, one per line, in the
       order given, and nothing else. Do not add, drop, reorder, renumber,
       paraphrase, prefix, merge, or re-punctuate a line, and add no preamble,
       commentary, advice, or values of your own.

    Branch 2 is reachable ONLY from a successful call whose result you actually
    read `silent` from. If you cannot point at that field in a returned result,
    you are in branch 1 — emit the 🛑 line, never `[SILENT]`.

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
    # This seed unit reads the unmodified family-only SOPS env, never the
    # gateway .env that preStart expands with Advisor Test.
    case "$signal_group_id" in
      group.*|*,*)
        echo "hermes weekly pulse: expected exactly one raw Family Advisor group ID" >&2
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
    job_id="$(${pkgs.gnugrep}/bin/grep -Eo '[0-9a-f]{12}' <<<"$block" | ${pkgs.coreutils}/bin/head -n 1)"
    if [[ -z "$job_id" ]]; then
      echo "hermes weekly pulse: could not determine persisted job ID" >&2
      exit 1
    fi

    ${hermesCli}/bin/hermes cron edit "$job_name" \
      --schedule "0 16 * * 5" \
      --prompt "$prompt" \
      --name "$job_name" \
      --deliver "signal:group:$signal_group_id" \
      --provider ${lib.escapeShellArg inferenceProvider} \
      --model ${lib.escapeShellArg inferenceModel} \
      --repeat 0 \
      --clear-skills >/dev/null

    # Recurring cron runs use fresh sessions. Feed this job its immediately
    # previous output so an unanswered 2-10-day candidate cannot be asked on
    # two consecutive Fridays; by the following run it has aged out.
    hermes_python="$(${pkgs.gnused}/bin/sed -n "s/^export HERMES_PYTHON='\(.*\)'$/\1/p" ${hermesPackage}/bin/hermes)"
    if [[ -z "$hermes_python" ]]; then
      echo "hermes weekly pulse: could not locate packaged Python" >&2
      exit 1
    fi
    HOME=${lib.escapeShellArg stateDir} \
      HERMES_HOME=${lib.escapeShellArg "${stateDir}/.hermes"} \
      "$hermes_python" - "$job_id" ${lib.escapeShellArg inferenceProvider} ${lib.escapeShellArg inferenceModel} <<'PY'
    import sys

    from cron.jobs import get_job, update_job

    job_id = sys.argv[1]
    updated = update_job(job_id, {"context_from": [job_id]})
    if not updated or updated.get("context_from") != [job_id]:
        raise SystemExit("weekly pulse self-context update failed")
    persisted = get_job(job_id)
    if (
        not persisted
        or persisted.get("provider") != sys.argv[2]
        or persisted.get("model") != sys.argv[3]
    ):
        raise SystemExit("weekly pulse inference pin update failed")
    PY

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
    # This seed unit reads the unmodified family-only SOPS env, never the
    # gateway .env that preStart expands with Advisor Test.
    case "$signal_group_id" in
      group.*|*,*)
        echo "hermes finance sentinel: expected exactly one raw Family Advisor group ID" >&2
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
    job_id="$(${pkgs.gnugrep}/bin/grep -Eo '[0-9a-f]{12}' <<<"$block" | ${pkgs.coreutils}/bin/head -n 1)"
    if [[ -z "$job_id" ]]; then
      echo "hermes finance sentinel: could not determine persisted job ID" >&2
      exit 1
    fi

    ${hermesCli}/bin/hermes cron edit "$job_name" \
      --schedule "$schedule" \
      --prompt "$prompt" \
      --name "$job_name" \
      --deliver "signal:group:$signal_group_id" \
      --provider ${lib.escapeShellArg inferenceProvider} \
      --model ${lib.escapeShellArg inferenceModel} \
      --repeat 0 \
      --clear-skills >/dev/null

    hermes_python="$(${pkgs.gnused}/bin/sed -n "s/^export HERMES_PYTHON='\(.*\)'$/\1/p" ${hermesPackage}/bin/hermes)"
    if [[ -z "$hermes_python" ]]; then
      echo "hermes finance sentinel: could not locate packaged Python" >&2
      exit 1
    fi
    HOME=${lib.escapeShellArg stateDir} \
      HERMES_HOME=${lib.escapeShellArg "${stateDir}/.hermes"} \
      "$hermes_python" - "$job_id" ${lib.escapeShellArg inferenceProvider} ${lib.escapeShellArg inferenceModel} <<'PY'
    import sys

    from cron.jobs import get_job

    persisted = get_job(sys.argv[1])
    if (
        not persisted
        or persisted.get("provider") != sys.argv[2]
        or persisted.get("model") != sys.argv[3]
    ):
        raise SystemExit("daily sentinel inference pin update failed")
    PY
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
  dailySentinelDryRunScript = pkgs.writeShellScript "hermes-daily-finance-sentinel-dry-run" ''
    set -euo pipefail

    export HOME="${stateDir}"
    export HERMES_HOME="${stateDir}/.hermes"
    job_name="${dailySentinelJobName}-dry-run"
    prompt="$(${pkgs.coreutils}/bin/cat ${dailySentinelPromptFile})"
    ${hermesCli}/bin/hermes cron remove "$job_name" >/dev/null 2>&1 || true

    create_output="$(${hermesCli}/bin/hermes cron create "1d" "$prompt" \
      --name "$job_name" \
      --deliver local)"
    job_id="$(${pkgs.gnugrep}/bin/grep -Eo '[0-9a-f]{12}' <<<"$create_output" | ${pkgs.coreutils}/bin/head -n 1)"
    if [[ -z "$job_id" ]]; then
      printf '%s\n' "$create_output" >&2
      echo "hermes finance sentinel dry run: could not determine job ID" >&2
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

    echo "hermes finance sentinel dry run: timed out; local job remains $job_id" >&2
    exit 1
  '';
  # Dead-man's switch for the daily sentinel.
  #
  # Silence is this job's success signal, which makes "it stopped running"
  # indistinguishable from "your finances are fine" to a human. On 2026-08-12
  # hermes lost its MCP connection for three days; the sentinel fired on time
  # every morning, the finance tools were absent from its toolset, and the
  # agent correctly refused to fabricate — but the household heard nothing and
  # no alarm was raised. Cron recorded all three runs as `completed` with
  # last_status `ok`, because the JOB succeeded; only its PURPOSE failed.
  #
  # So this checks liveness AND substance, and runs from its own unit with its
  # own alarm path: a watcher living inside hermes cannot report that hermes
  # has stopped.
  sentinelHeartbeatScript = pkgs.writeScript "hermes-sentinel-heartbeat" ''
    #!${pkgs.python3}/bin/python3
    """Assert the daily finance sentinel both ran and could see the data."""
    import datetime
    import glob
    import json
    import os
    import sys

    HERMES_HOME = "${stateDir}/.hermes"
    JOB_NAME = "${dailySentinelJobName}"
    MAX_AGE_H = 26.0

    def fail(msg):
        print("hermes sentinel heartbeat: " + msg, file=sys.stderr)
        raise SystemExit(1)

    jobs_path = os.path.join(HERMES_HOME, "cron", "jobs.json")
    try:
        with open(jobs_path) as fh:
            raw = json.load(fh)
    except Exception as exc:
        fail("cannot read %s: %s" % (jobs_path, exc))

    jobs = raw if isinstance(raw, list) else raw.get("jobs", raw)
    if isinstance(jobs, dict):
        jobs = list(jobs.values())

    job = next(
        (j for j in jobs if isinstance(j, dict) and j.get("name") == JOB_NAME),
        None,
    )
    if job is None:
        fail("no cron job named %s - the sentinel is not scheduled at all" % JOB_NAME)
    if not job.get("enabled", False):
        fail("%s is disabled" % JOB_NAME)
    if job.get("paused_at"):
        fail("%s is paused: %s" % (JOB_NAME, job.get("paused_reason")))

    last_run = job.get("last_run_at")
    if not last_run:
        fail("%s has never run" % JOB_NAME)
    try:
        ran_at = datetime.datetime.fromisoformat(last_run)
    except ValueError as exc:
        fail("%s has an unparseable last_run_at %r: %s" % (JOB_NAME, last_run, exc))
    age_h = (datetime.datetime.now(ran_at.tzinfo) - ran_at).total_seconds() / 3600.0
    if age_h > MAX_AGE_H:
        fail(
            "%s last ran %.1fh ago, limit %.0fh. It is scheduled daily, so the "
            "household has had no finance sentinel since %s."
            % (JOB_NAME, age_h, MAX_AGE_H, last_run)
        )

    if job.get("last_status") not in (None, "ok"):
        fail(
            "%s last_status=%r error=%r"
            % (JOB_NAME, job.get("last_status"), job.get("last_error"))
        )
    if job.get("last_delivery_error"):
        fail("%s ran but delivery failed: %s" % (JOB_NAME, job["last_delivery_error"]))

    # A run can be `ok` and still blind. These are the shapes a blind run takes:
    # the current prompt's explicit failure branch, and the free-text refusals
    # the previous prompt produced on 2026-08-12..14.
    out_dir = os.path.join(HERMES_HOME, "cron", "output", job.get("id", ""))
    runs = sorted(glob.glob(os.path.join(out_dir, "*.md")))
    if not runs:
        fail("%s has no run output under %s" % (JOB_NAME, out_dir))
    newest = runs[-1]
    with open(newest, errors="replace") as fh:
        body = fh.read()
    verdict = body.split("## Response", 1)[-1].strip()
    if not verdict:
        fail("%s produced an empty verdict in %s" % (JOB_NAME, os.path.basename(newest)))

    BLIND = (
        "sentinel could not run",
        "cannot complete this task",
        "not available in my current toolset",
        "not present in my available toolset",
    )
    for marker in BLIND:
        if marker in verdict.lower():
            fail(
                "%s ran at %s but could not evaluate the finances (%r in %s). "
                "Check whether the MCP servers are parked: "
                "journalctl -t hermes-errors -g parking"
                % (JOB_NAME, last_run, marker, os.path.basename(newest))
            )

    print(
        "ok: %s ran %.1fh ago, verdict readable (%s)"
        % (JOB_NAME, age_h, os.path.basename(newest))
    )
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
            "finances_context_add"
            "finances_context_list"
            "finances_clarify_candidates"
            "finances_ticklers"
            # The daily sentinel, as one call. It performs the four reads
            # itself and returns `silent` plus the exact lines to send; the
            # cron prompt shrinks to rendering them. The four reads stay in
            # this list because the weekly pulse still calls them directly.
            # Mirrors HOMELAB_MCP_RESTRICTED_SCOPES.hermes in
            # services/homelab-mcp.nix, which is the authoritative boundary —
            # both must name it or the tool is invisible here or 403 there.
            "finances_sentinel"
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
          model = {
            provider = inferenceProvider;
            default = inferenceModel;
          };
          plugins.enabled = [ "household-scribe-guard" ];
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
            # Hermes v0.19 resolves channel overrides every turn and includes
            # their full text in the cached-agent signature, so persona edits
            # do not require session resets. Acceptance MUST use the production
            # identity below with thread_id=null: synthetic thread IDs create a
            # different session and do not exercise Ryan's persistent DM history.
            channel_overrides."8903896206".system_prompt = nonFinanceGatewayPrompt;
          };
          gateway.platforms.signal = {
            enabled = true;
            # SIGNAL_ALLOWED_USERS is mirrored into the SOPS env. An explicit
            # allowlist makes unauthorized DMs silent instead of issuing
            # pairing codes; group intake is separately restricted by
            # SIGNAL_GROUP_ALLOWED_USERS. preStart expands that gateway-only
            # allowlist with Advisor Test and installs this same persona for
            # both group chat IDs. Scheduled units continue reading the
            # untouched family-only SOPS env. The scribe plugin hard-denies
            # finances_context_add for Advisor Test before MCP execution.
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

        # Remove the decoy log directory. Hermes created ${stateDir}/logs once
        # on 2026-08-02 with an empty agent.log and errors.log, then never
        # touched it again — it survived three service restarts still at 0
        # bytes while the real logs filled up under .hermes/logs. It is not a
        # spare or a fallback, it is a trap: investigating the August 2026 MCP
        # outage, an empty agent.log here read as "hermes logs nothing" and
        # sent the diagnosis down the wrong path, while the evidence sat in
        # .hermes/logs/errors.log the whole time. One logs directory only.
        "R ${stateDir}/logs - - - -"
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
        # Render the SOPS-held family and test group IDs into exact Signal chat
        # keys before startup. Only the gateway's merged .env receives both
        # allowed IDs; cron seed units retain the family-only source secret.
        # Then wait for the REST API so the initial connect is not lost while
        # the json-rpc daemon is still warming up.
        preStart = ''
          mkdir -p "${stateDir}/.hermes/plugins"
          ln -sfnT ${householdScribeGuardPlugin} \
            "${stateDir}/.hermes/plugins/household-scribe-guard"

          readEnvValue() {
            ${pkgs.gawk}/bin/awk -F= -v key="$1" '
            $1 == key {
              sub(/^[^=]*=/, "")
              value = $0
            }
            END {
              if (value == "") exit 1
              print value
            }
            ' "$2"
          }

          familyGroupId="$(readEnvValue SIGNAL_GROUP_ALLOWED_USERS "$CREDENTIALS_DIRECTORY/signal-env")"
          advisorTestGroupId="$(${pkgs.coreutils}/bin/cat "$CREDENTIALS_DIRECTORY/advisor-test-group-id")"

          case "$familyGroupId" in
            group.*|*,*)
              echo "hermes-agent: Family Advisor must be exactly one raw Signal group ID" >&2
              exit 1
              ;;
            ?*) ;;
            *)
              echo "hermes-agent: Family Advisor group ID is missing" >&2
              exit 1
              ;;
          esac
          case "$advisorTestGroupId" in
            group.*|*,*)
              echo "hermes-agent: Advisor Test must be exactly one raw Signal group ID" >&2
              exit 1
              ;;
            ?*) ;;
            *)
              echo "hermes-agent: Advisor Test group ID is missing" >&2
              exit 1
              ;;
          esac
          if [[ "$familyGroupId" == "$advisorTestGroupId" ]]; then
            echo "hermes-agent: Family Advisor and Advisor Test group IDs must differ" >&2
            exit 1
          fi

          envFile="${stateDir}/.hermes/.env"
          allowlistTmp="$envFile.signal-groups.$$"
          trap '${pkgs.coreutils}/bin/rm -f "$allowlistTmp"' EXIT
          ${pkgs.gawk}/bin/awk -F= -v groups="$familyGroupId,$advisorTestGroupId" '
            $1 == "SIGNAL_GROUP_ALLOWED_USERS" {
              if (!written) print "SIGNAL_GROUP_ALLOWED_USERS=" groups
              written = 1
              next
            }
            { print }
            END {
              if (!written) print "SIGNAL_GROUP_ALLOWED_USERS=" groups
            }
          ' "$envFile" > "$allowlistTmp"
          ${pkgs.coreutils}/bin/install -o hermes -g hermes -m 0640 "$allowlistTmp" "$envFile"
          ${pkgs.coreutils}/bin/rm -f "$allowlistTmp"
          trap - EXIT

          SIGNAL_FAMILY_GROUP_CHAT_ID="group:$familyGroupId" \
          SIGNAL_ADVISOR_TEST_CHAT_ID="group:$advisorTestGroupId" \
          HOUSEHOLD_ADVISOR_PROMPT="$(${pkgs.coreutils}/bin/cat ${pkgs.writeText "household-advisor-prompt" householdAdvisorPrompt})" \
            ${pkgs.yq-go}/bin/yq --inplace \
              '.gateway.platforms.signal.channel_overrides |= with_entries(select(.key | test("^group:") | not)) |
               .gateway.platforms.signal.channel_overrides[strenv(SIGNAL_FAMILY_GROUP_CHAT_ID)].system_prompt = strenv(HOUSEHOLD_ADVISOR_PROMPT) |
               .gateway.platforms.signal.channel_overrides[strenv(SIGNAL_ADVISOR_TEST_CHAT_ID)].system_prompt = strenv(HOUSEHOLD_ADVISOR_PROMPT)' \
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
          householdScribeGuardPlugin
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
          LoadCredential = [
            "signal-env:${config.sops.secrets."hermes-agent/signal-env".path}"
            "advisor-test-group-id:${config.sops.secrets."hermes-agent/advisor-test-group-id".path}"
          ];
        };
      };

      # Hermes logs ONLY to files — hermes_logging.py wires every logger to a
      # RotatingFileHandler under ${stateDir}/.hermes/logs and writes nothing to
      # stdout, so `journalctl -u hermes-agent` returns zero records however
      # long the service has run. The 2026-08-12 MCP outage announced itself
      # there ~890 times over three days ("failed initial connection ...
      # parking until a reconnect is requested: TimeoutError") while the
      # household got no sentinel and nothing raised an alarm. The data existed;
      # only surfacing was missing.
      #
      # Mirror the high-signal error stream into the journal so journal-based
      # tooling and alerting can see it at all. errors.log only: agent.log is
      # ~10x the volume and mostly routine, and journald is a shared budget.
      systemd.services.hermes-agent-log-relay = {
        description = "Mirror Hermes file logs into the journal";
        after = [ "hermes-agent.service" ];
        wants = [ "hermes-agent.service" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = pulseServiceHardening // {
          # -F (follow by name, retry) survives both the RotatingFileHandler's
          # rename-and-recreate and a not-yet-created file on first boot.
          # -n 0 starts at the tail: the backlog is already on disk, and
          # replaying it on every restart would duplicate it into the journal.
          ExecStart = "${pkgs.coreutils}/bin/tail -F -n 0 ${stateDir}/.hermes/logs/errors.log";
          SyslogIdentifier = "hermes-errors";
          StandardOutput = "journal";
          StandardError = "journal";
          Restart = "always";
          RestartSec = 5;
          # Read-only: this unit must never be able to perturb what it watches.
          # `//` already replaces the hardening set's ReadWritePaths outright;
          # with ProtectSystem=strict and nothing writable, stateDir is
          # readable and untouchable.
          ReadWritePaths = [ ];
          MemoryMax = "64M";
          TasksMax = 8;
        };
      };

      # Alarm path for the heartbeat below. Deliberately NOT Signal: Signal is
      # how the sentinel itself speaks, and an alarm that shares a channel with
      # the thing it watches can be silenced by the same fault. notify@ goes to
      # Pushover and touches neither hermes nor the MCP server.
      modules.notifications.templates.hermes-sentinel-stale =
        lib.mkIf (config.modules.notifications.enable or false) {
          priority = lib.mkDefault "high";
          title = "🛑 Household finance sentinel is not reporting";
          body = ''
            The daily finance sentinel has not produced a usable verdict.

            Silence normally means "nothing to report", so this alarm exists
            because a stopped sentinel and a healthy morning look identical
            from the outside.

            Check: systemctl status hermes-agent-sentinel-heartbeat.service
            Parked MCP servers: journalctl -t hermes-errors -g parking
          '';
        };

      systemd.services.hermes-agent-sentinel-heartbeat = {
        description = "Assert the daily finance sentinel ran and could see data";
        # No dependency on hermes-agent: this must still run, and still be able
        # to complain, when hermes is wedged, stopped, or gone.
        onFailure = [ "notify@hermes-sentinel-stale:%n.service" ];
        serviceConfig = pulseServiceHardening // {
          Type = "oneshot";
          ExecStart = sentinelHeartbeatScript;
          # Reads hermes's cron state; must never be able to alter it.
          ReadWritePaths = [ ];
          MemoryMax = "128M";
          TasksMax = 16;
        };
      };

      systemd.timers.hermes-agent-sentinel-heartbeat = {
        description = "Check the daily finance sentinel is still reporting";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          # The sentinel runs daily at 08:00 and the check tolerates 26h, so a
          # 6-hourly sweep bounds "nobody noticed" at about six hours instead
          # of the three days it actually took in August 2026.
          OnCalendar = "*-*-* 00,06,12,18:20:00";
          RandomizedDelaySec = "5m";
          Persistent = true;
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

      # Manual acceptance path for the daily sentinel. Like the weekly dry run,
      # this creates a disposable local-only job and never runs the production
      # Signal-delivery job ID.
      systemd.services.hermes-agent-daily-finance-sentinel-dry-run = {
        description = "Compose a local-only Hermes daily finance sentinel";
        after = [ "hermes-agent.service" ];
        requires = [ "hermes-agent.service" ];
        serviceConfig = pulseServiceHardening // {
          Type = "oneshot";
          PrivateNetwork = false;
          RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
          ExecStart = dailySentinelDryRunScript;
          TimeoutStartSec = "11min";
        };
      };
    })
  ];
}
