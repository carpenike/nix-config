# Grafana boards over the schoolhouse store.
#
# WHY A DASHBOARD AND NOT JUST THE MCP TOOLS. Two reasons, and the second is
# the one that matters.
#
# The queue only works if somebody drains it. `parser_gaps` records what the
# ingest could not read, and for its first fortnight the only way to look was
# to ask an assistant to run a query — so a letter grade sat unrecorded for
# three days with the evidence already sitting in the table. A panel is the
# drain that queue was always missing.
#
# And this data is three minors' education records. Every question answered
# here is a question that does not leave the house; asking the same question
# conversationally ships names, courses and grades to someone else's
# inference API. Self-hosted behind Pocket ID is the more private surface,
# not the less private one.
#
# What deliberately is NOT here: "what does my kid owe right now". That answer
# needs the observed-versus-inferred distinction and the gap caveat attached
# to it, and a table of ten rows headed "missing" is exactly the false
# positive this service spent a fortnight learning not to emit.
{ pkgs }:

let
  datasource = {
    type = "grafana-postgresql-datasource";
    uid = "schoolhouse";
  };

  colors = {
    green = "#078C52";
    amber = "#F79009";
    red = "#F13636";
    blue = "#2E90FA";
    gray = "#737373";
  };

  query =
    { sql, refId ? "A", format ? "time_series", hide ? false }:
    {
      inherit datasource format hide refId;
      editorMode = "code";
      rawQuery = true;
      rawSql = sql;
    };

  gridPos = h: w: x: y: { inherit h w x y; };

  fieldOverride = name: properties: {
    matcher = { id = "byName"; options = name; };
    inherit properties;
  };

  timeSeriesCustom =
    { fillOpacity ? 12, drawStyle ? "line", showPoints ? "auto", lineWidth ? 2 }:
    {
      axisBorderShow = false;
      axisCenteredZero = false;
      axisColorMode = "text";
      axisLabel = "";
      axisPlacement = "auto";
      barAlignment = 0;
      inherit drawStyle fillOpacity lineWidth showPoints;
      gradientMode = "none";
      hideFrom = { legend = false; tooltip = false; viz = false; };
      insertNulls = false;
      lineInterpolation = "linear";
      pointSize = 5;
      scaleDistribution.type = "linear";
      spanNulls = true;
      stacking = { group = "A"; mode = "none"; };
      thresholdsStyle.mode = "off";
    };

  timeSeriesOptions = {
    legend = { calcs = [ ]; displayMode = "list"; placement = "bottom"; showLegend = true; };
    tooltip = { mode = "multi"; sort = "desc"; };
  };

  tableOptions = {
    cellHeight = "sm";
    footer = { countRows = false; fields = ""; reducer = [ "sum" ]; show = false; };
    showHeader = true;
  };

  noThresholds = { mode = "absolute"; steps = [{ color = "text"; value = null; }]; };

  # A picker over one column. `$__all` expands to every option, so a panel's
  # SQL needs no special case for "all" — which is why every filtered query
  # below reads the same whether one child is selected or three.
  pick = { name, label, sql, allValue ? null }: {
    inherit name label;
    type = "query";
    datasource = datasource;
    query = sql;
    definition = sql;
    multi = true;
    includeAll = true;
    inherit allValue;
    refresh = 1;
    sort = 1;
    hide = 0;
    current = { text = [ "All" ]; value = [ "$__all" ]; };
    options = [ ];
    regex = "";
    skipUrlSync = false;
  };

  childPicker = pick {
    name = "child";
    label = "Child";
    sql = "SELECT display_name FROM children WHERE active ORDER BY display_name";
  };

  # Chained to the child picker, so choosing one kid narrows the course list
  # instead of offering every course in the house.
  coursePicker = pick {
    name = "course";
    label = "Course";
    sql =
      "SELECT DISTINCT c.title FROM courses c JOIN children ch ON ch.id = c.child_id"
      # `\${` in a DOUBLE-quoted string; `''${` is the escape for indented
      # strings only. Written the other way round, Nix reads `child:sqlstring`
      # as a legacy URI literal and the query builds as `IN (''child:sqlstring)`
      # — which statix caught and the built JSON confirmed.
      + " WHERE c.active AND ch.display_name IN (\${child:sqlstring}) ORDER BY c.title";
  };

  stat = { id, title, description, sql, gridPos, unit ? "", decimals ? 0, steps }: {
    inherit id title description gridPos;
    type = "stat";
    datasource = datasource;
    targets = [ (query { inherit sql; format = "table"; }) ];
    fieldConfig = {
      defaults = {
        inherit unit decimals;
        color.mode = "thresholds";
        thresholds = { mode = "absolute"; inherit steps; };
      };
      overrides = [ ];
    };
    options = {
      colorMode = "value";
      graphMode = "none";
      justifyMode = "auto";
      orientation = "auto";
      reduceOptions = { calcs = [ "lastNotNull" ]; fields = ""; values = false; };
      textMode = "auto";
    };
  };

  table = { id, title, description, sql, gridPos, overrides ? [ ], sortBy ? [ ] }: {
    inherit id title description gridPos;
    type = "table";
    datasource = datasource;
    targets = [ (query { inherit sql; format = "table"; }) ];
    fieldConfig = {
      defaults = {
        custom = {
          align = "auto";
          cellOptions.type = "auto";
          filterable = true;
          inspect = false;
        };
        thresholds = noThresholds;
      };
      inherit overrides;
    };
    options = tableOptions // { inherit sortBy; };
  };

  dashboard =
    { title
    , uid
    , description
    , panels
    , refresh ? "5m"
    , variables ? [ ]
    , from ? "now-30d"
    }: {
      inherit title uid description panels refresh;
      annotations.list = [ ];
      editable = false;
      graphTooltip = 1;
      schemaVersion = 39;
      tags = [ "schoolhouse" "household" ];
      templating.list = variables;
      time = { inherit from; to = "now"; };
      timezone = "America/New_York";
      weekStart = "";
    };


  # ── 1. is the sync working ──────────────────────────────────────────
  # Operator board. No child data at all, so it answers "is it running"
  # without putting a grade on screen to do it.
  health = dashboard {
    title = "Schoolhouse — Sync health";
    uid = "schoolhouse-health";
    description =
      "Whether the scraper is running and reading everything it fetches. "
      + "`partial` is not a fault: it means a parser declined to guess. The "
      + "queue itself lives on its own board.";
    panels = [
      (stat {
        id = 1;
        title = "Since last run";
        description = "The timer is 7am and 4pm on weekdays, so past ~18h is stale.";
        gridPos = gridPos 5 6 0 0;
        unit = "h";
        decimals = 1;
        sql = ''
          SELECT EXTRACT(EPOCH FROM now() - max(finished_at)) / 3600 AS "Hours"
          FROM ingest_runs WHERE source = 'scraper' AND finished_at IS NOT NULL
        '';
        steps = [
          { color = colors.green; value = null; }
          { color = colors.amber; value = 18; }
          { color = colors.red; value = 36; }
        ];
      })
      (stat {
        id = 2;
        title = "Pages read";
        description = "Grew from 69 to ~141 as folder walking and the To Do page were added.";
        gridPos = gridPos 5 6 6 0;
        sql = ''
          SELECT pages_fetched::int AS "Pages" FROM ingest_runs
          WHERE source = 'scraper' AND finished_at IS NOT NULL
          ORDER BY id DESC LIMIT 1
        '';
        steps = [{ color = colors.blue; value = null; }];
      })
      (stat {
        id = 3;
        title = "Held back";
        description =
          "Payloads whose records were discarded because a parser could not "
          + "trust them. Zero is the normal state; anything else means a page "
          + "changed shape.";
        gridPos = gridPos 5 6 12 0;
        sql = ''
          SELECT parsers_pending::int AS "Held" FROM ingest_runs
          WHERE source = 'scraper' AND finished_at IS NOT NULL
          ORDER BY id DESC LIMIT 1
        '';
        steps = [
          { color = colors.green; value = null; }
          { color = colors.red; value = 1; }
        ];
      })
      (stat {
        id = 4;
        title = "Open gaps";
        description = "Detail on the Review queue board.";
        gridPos = gridPos 5 6 18 0;
        sql = ''SELECT count(*)::int AS "Gaps" FROM open_parser_gaps'';
        steps = [
          { color = colors.green; value = null; }
          { color = colors.amber; value = 1; }
          { color = colors.red; value = 15; }
        ];
      })
      {
        id = 5;
        type = "timeseries";
        title = "What each run saw";
        description =
          "A drop in records with no drop in pages means a parser started "
          + "refusing something — the signal, not a fault.";
        datasource = datasource;
        gridPos = gridPos 9 24 0 5;
        targets = [
          (query {
            sql = ''
              SELECT finished_at AS time,
                     pages_fetched::double precision AS "Pages",
                     records_seen::double precision AS "Records seen",
                     records_changed::double precision AS "Records changed"
              FROM ingest_runs
              WHERE source = 'scraper' AND finished_at IS NOT NULL
                AND $__timeFilter(finished_at)
              ORDER BY finished_at
            '';
          })
        ];
        fieldConfig = {
          defaults = {
            color.mode = "palette-classic";
            custom = timeSeriesCustom { };
            thresholds = noThresholds;
          };
          overrides = [
            (fieldOverride "Records changed" [{
              id = "color";
              value = { fixedColor = colors.blue; mode = "fixed"; };
            }])
          ];
        };
        options = timeSeriesOptions;
      }
    ];
  };

  # ── 2. the worklist ─────────────────────────────────────────────────
  queue = dashboard {
    title = "Schoolhouse — Review queue";
    uid = "schoolhouse-queue";
    description =
      "What the ingest could not read, worst first. `affects` names the ANSWER "
      + "a row qualifies, so anything listed here means that answer may be "
      + "incomplete. Evidence is kept in its own panel so the worklist stays "
      + "scannable.";
    variables = [
      childPicker
      (pick {
        name = "affects";
        label = "Affects";
        sql = ''
          SELECT unnest(ARRAY['missing_work','upcoming_work','grades',
                              'announcements','courses','staff','other']) ORDER BY 1
        '';
      })
    ];
    panels = [
      (stat {
        id = 1;
        title = "Open";
        description = "Distinct blind spots, not affected payloads.";
        gridPos = gridPos 4 8 0 0;
        sql = ''
          SELECT count(*)::int AS "Open" FROM open_parser_gaps
          WHERE affects IN (''${affects:sqlstring})
            AND (child_name IS NULL OR child_name IN (''${child:sqlstring}))
        '';
        steps = [
          { color = colors.green; value = null; }
          { color = colors.amber; value = 1; }
        ];
      })
      (stat {
        id = 2;
        title = "Needs a person";
        description =
          "Excludes anything waiting on a date that has not arrived — there is "
          + "genuinely nothing to learn from those yet.";
        gridPos = gridPos 4 8 8 0;
        sql = ''
          SELECT count(*)::int AS "Actionable" FROM open_parser_gaps
          WHERE actionable AND affects IN (''${affects:sqlstring})
            AND (child_name IS NULL OR child_name IN (''${child:sqlstring}))
        '';
        steps = [
          { color = colors.green; value = null; }
          { color = colors.amber; value = 1; }
        ];
      })
      (stat {
        id = 3;
        title = "Longest open";
        description = "Days since the oldest listed gap was first raised.";
        gridPos = gridPos 4 8 16 0;
        unit = "d";
        sql = ''
          SELECT COALESCE(EXTRACT(EPOCH FROM now() - min(first_seen_at)) / 86400, 0) AS "Days"
          FROM open_parser_gaps
          WHERE affects IN (''${affects:sqlstring})
            AND (child_name IS NULL OR child_name IN (''${child:sqlstring}))
        '';
        steps = [
          { color = colors.green; value = null; }
          { color = colors.amber; value = 7; }
          { color = colors.red; value = 30; }
        ];
      })
      (table {
        id = 4;
        title = "Worklist";
        description = "Seven columns, worst first. The evidence is below.";
        gridPos = gridPos 9 24 0 4;
        sql = ''
          SELECT severity AS "Sev",
                 affects AS "Affects",
                 COALESCE(child_name, 'all') AS "Child",
                 COALESCE(course_title, NULLIF(section_id, '''), ''') AS "Course",
                 reason AS "Reason",
                 times_seen AS "Seen",
                 actionable AS "Now"
          FROM open_parser_gaps
          WHERE affects IN (''${affects:sqlstring})
            AND (child_name IS NULL OR child_name IN (''${child:sqlstring}))
          ORDER BY severity, last_seen_at DESC
        '';
        sortBy = [{ desc = false; displayName = "Sev"; }];
        overrides = [
          (fieldOverride "Sev" [
            { id = "custom.cellOptions"; value = { type = "color-background"; mode = "gradient"; }; }
            {
              id = "thresholds";
              value = {
                mode = "absolute";
                steps = [
                  { color = colors.red; value = null; }
                  { color = colors.amber; value = 3; }
                  { color = colors.gray; value = 5; }
                ];
              };
            }
            { id = "custom.width"; value = 60; }
          ])
          (fieldOverride "Seen" [{ id = "custom.width"; value = 70; }])
          (fieldOverride "Now" [{ id = "custom.width"; value = 70; }])
        ];
      })
      (table {
        id = 5;
        title = "Evidence";
        description =
          "What each gap actually saw. This is what a fixture is captured "
          + "from, so it is the difference between a worklist and a to-do list.";
        gridPos = gridPos 8 24 0 13;
        sql = ''
          SELECT COALESCE(child_name, 'all') AS "Child",
                 kind AS "Page",
                 reason AS "Reason",
                 detail::text AS "Saw"
          FROM open_parser_gaps
          WHERE affects IN (''${affects:sqlstring})
            AND (child_name IS NULL OR child_name IN (''${child:sqlstring}))
          ORDER BY severity, last_seen_at DESC
        '';
        overrides = [ (fieldOverride "Saw" [{ id = "custom.width"; value = 620; }]) ];
      })
    ];
  };

  # ── 3. grades ───────────────────────────────────────────────────────
  # The trajectory chart is why this board has filters. Unfiltered it draws
  # one line per child-and-course — twelve of them from eighteen points on
  # the day this was written, and worse every week. One child at a time is
  # the only way it reads as anything.
  grades = dashboard {
    title = "Schoolhouse — Grades";
    uid = "schoolhouse-grades";
    description =
      "Course grades and how they moved. `course_grades` only appends when a "
      + "value changes, so the line is real history rather than a resampled "
      + "snapshot. A letter-only grade carries no percentage and appears in "
      + "the table but not the chart.";
    from = "now-90d";
    variables = [ childPicker coursePicker ];
    panels = [
      {
        id = 1;
        type = "timeseries";
        title = "How each grade has moved";
        description = "Pick one child to read it. Points, not lines, where a course has a single observation.";
        datasource = datasource;
        gridPos = gridPos 11 24 0 0;
        targets = [
          (query {
            sql = ''
              SELECT g.observed_at AS time,
                     g.percent::double precision AS value,
                     ch.display_name || ' · ' || c.title AS metric
              FROM course_grades g
              JOIN courses c ON c.id = g.course_id
              JOIN children ch ON ch.id = c.child_id
              WHERE g.percent IS NOT NULL
                AND c.active
                AND ch.display_name IN (''${child:sqlstring})
                AND c.title IN (''${course:sqlstring})
                AND $__timeFilter(g.observed_at)
              ORDER BY g.observed_at
            '';
          })
        ];
        fieldConfig = {
          defaults = {
            unit = "percent";
            min = 0;
            max = 105;
            color.mode = "palette-classic";
            custom = timeSeriesCustom { fillOpacity = 0; showPoints = "always"; };
            thresholds = noThresholds;
          };
          overrides = [ ];
        };
        options = timeSeriesOptions;
      }
      (table {
        id = 2;
        title = "Where each course stands";
        description = "Latest observation per course and marking period, including letter-only grades.";
        gridPos = gridPos 10 24 0 11;
        sql = ''
          SELECT ch.display_name AS "Child",
                 c.title AS "Course",
                 COALESCE(s.display_name, NULLIF(c.teacher, '''), '—') AS "Teacher",
                 g.percent AS "Percent",
                 NULLIF(g.letter, ''') AS "Letter",
                 g.observed_at AT TIME ZONE 'America/New_York' AS "As of"
          FROM latest_course_grade g
          JOIN courses c ON c.id = g.course_id
          JOIN children ch ON ch.id = c.child_id
          LEFT JOIN staff s ON s.schoology_uid = c.teacher_uid
          WHERE c.active
            AND ch.display_name IN (''${child:sqlstring})
            AND c.title IN (''${course:sqlstring})
          ORDER BY ch.display_name, c.title
        '';
        overrides = [
          (fieldOverride "Percent" [
            { id = "unit"; value = "percent"; }
            { id = "decimals"; value = 1; }
            { id = "custom.cellOptions"; value = { type = "color-text"; }; }
            {
              id = "thresholds";
              value = {
                mode = "absolute";
                steps = [
                  { color = colors.red; value = null; }
                  { color = colors.amber; value = 70; }
                  { color = colors.green; value = 85; }
                ];
              };
            }
          ])
          (fieldOverride "Letter" [{ id = "custom.width"; value = 80; }])
        ];
      })
    ];
  };

  # ── 4. work ─────────────────────────────────────────────────────────
  work = dashboard {
    title = "Schoolhouse — Work";
    uid = "schoolhouse-work";
    description =
      "What is outstanding and what is coming. Lateness is computed from the "
      + "due date, never read from Schoology's own wording — that page labels "
      + "work due in five days '4 days overdue'. Late and Unknown are two "
      + "different questions and are counted separately: Late is what "
      + "Schoology reports outstanding, Unknown is what it has never said "
      + "anything about. Reading Late alone understates the picture, which "
      + "is exactly what this board used to do.";
    from = "now-7d";
    variables = [ childPicker ];
    panels = [
      (stat {
        id = 1;
        title = "Late";
        description =
          "Schoology itself reports these outstanding, and the due date has "
          + "passed. This is the half we actually know about — read it next "
          + "to Unknown, never on its own.";
        gridPos = gridPos 4 6 0 0;
        sql = ''
          SELECT count(*)::int AS "Late"
          FROM assignments a
          JOIN courses c ON c.id = a.course_id
          JOIN children ch ON ch.id = c.child_id
          JOIN latest_assignment_state s ON s.assignment_id = a.id
          WHERE s.status = 'assigned' AND c.active AND a.due_at < now()
            AND ch.display_name IN (''${child:sqlstring})
        '';
        steps = [
          { color = colors.green; value = null; }
          { color = colors.amber; value = 1; }
          { color = colors.red; value = 5; }
        ];
      })
      # The panel this board was missing, and the reason a child with real
      # blind spots could read as entirely clear. The gradebook shows a bare
      # em-dash for these: no score, no submission icon, nothing. Schoology
      # cannot distinguish "not yet graded" from "never turned in", so
      # neither can we, and the honest answer is to say we do not know rather
      # than to leave the row out of the query.
      #
      # This is the same population the MCP returns as basis=inferred_past_due
      # in school_get_missing_work. The two must agree; they did not before,
      # because the Late panel above inner-joins the state table and anything
      # with no state at all silently vanished.
      (stat {
        id = 6;
        title = "Unknown";
        description =
          "Past due, and no submission state has ever been observed. NOT a "
          + "count of missed work — it is a count of questions the store "
          + "cannot answer, and each one needs a human to look.";
        gridPos = gridPos 4 6 6 0;
        sql = ''
          SELECT count(*)::int AS "Unknown"
          FROM assignments a
          JOIN courses c ON c.id = a.course_id
          JOIN children ch ON ch.id = c.child_id
          LEFT JOIN latest_assignment_state s ON s.assignment_id = a.id
          WHERE s.assignment_id IS NULL AND c.active AND a.due_at < now()
            AND ch.display_name IN (''${child:sqlstring})
        '';
        steps = [
          { color = colors.green; value = null; }
          { color = colors.amber; value = 1; }
        ];
      })
      (stat {
        id = 2;
        title = "Due in 7 days";
        gridPos = gridPos 4 6 12 0;
        description = "Everything dated in the coming week, whatever its state.";
        sql = ''
          SELECT count(*)::int AS "Due"
          FROM assignments a
          JOIN courses c ON c.id = a.course_id
          JOIN children ch ON ch.id = c.child_id
          WHERE c.active AND a.due_at BETWEEN now() AND now() + interval '7 days'
            AND ch.display_name IN (''${child:sqlstring})
        '';
        steps = [{ color = colors.blue; value = null; }];
      })
      (stat {
        id = 3;
        title = "Undated";
        description =
          "Work the store knows about but cannot place in time, so it can "
          + "never appear in a 'what is due this week' answer. Materials "
          + "carries no due date; the gradebook and the To Do page do.";
        gridPos = gridPos 4 6 18 0;
        sql = ''
          SELECT count(*)::int AS "Undated"
          FROM assignments a
          JOIN courses c ON c.id = a.course_id
          JOIN children ch ON ch.id = c.child_id
          WHERE c.active AND a.due_at IS NULL
            AND ch.display_name IN (''${child:sqlstring})
        '';
        steps = [
          { color = colors.green; value = null; }
          { color = colors.amber; value = 1; }
        ];
      })
      (table {
        id = 4;
        title = "Outstanding, soonest first";
        description =
          "`State` is computed here from the due date, never read from "
          + "Schoology's wording. `Basis` says how much to trust the row: "
          + "*observed* means Schoology reports it not turned in; *inferred* "
          + "means the due date passed and no submission state was ever seen, "
          + "which often just means nobody has graded it yet. Same vocabulary "
          + "as school_get_missing_work, deliberately — the two must agree.";
        gridPos = gridPos 9 24 0 4;
        # LEFT JOIN, not JOIN. The inner join here is what hid every
        # never-observed assignment from this table, and a child whose only
        # past-due work was unobserved read as completely clear.
        sql = ''
          SELECT ch.display_name AS "Child",
                 c.title AS "Course",
                 a.title AS "Work",
                 a.due_at AT TIME ZONE 'America/New_York' AS "Due",
                 CASE WHEN a.due_at < now() THEN 'late' ELSE 'ahead' END AS "State",
                 CASE WHEN s.assignment_id IS NULL THEN 'inferred'
                      ELSE 'observed' END AS "Basis"
          FROM assignments a
          JOIN courses c ON c.id = a.course_id
          JOIN children ch ON ch.id = c.child_id
          LEFT JOIN latest_assignment_state s
            ON s.assignment_id = a.id AND s.status = 'assigned'
          WHERE a.due_at IS NOT NULL AND c.active
            AND (
              -- Schoology says it is outstanding, whenever it is due.
              s.assignment_id IS NOT NULL
              -- Or it is past due and the store has never seen any state
              -- for it at all. Future-dated work with no state yet is
              -- simply not started, and belongs in "Due in 7 days".
              OR (a.due_at < now()
                  AND NOT EXISTS (SELECT 1 FROM latest_assignment_state x
                                  WHERE x.assignment_id = a.id))
            )
            AND ch.display_name IN (''${child:sqlstring})
          ORDER BY a.due_at
        '';
        overrides = [
          (fieldOverride "State" [
            { id = "custom.cellOptions"; value = { type = "color-text"; }; }
            {
              id = "mappings";
              value = [{
                type = "value";
                options = {
                  late = { color = colors.red; index = 0; text = "late"; };
                  ahead = { color = colors.green; index = 1; text = "ahead"; };
                };
              }];
            }
            { id = "custom.width"; value = 90; }
          ])
          # Amber, not red. An inferred row is a question, not a verdict —
          # colouring it like a confirmed miss would tell a parent something
          # the store does not actually know.
          (fieldOverride "Basis" [
            { id = "custom.cellOptions"; value = { type = "color-text"; }; }
            {
              id = "mappings";
              value = [{
                type = "value";
                options = {
                  observed = { color = colors.red; index = 0; text = "observed"; };
                  inferred = { color = colors.amber; index = 1; text = "inferred"; };
                };
              }];
            }
            { id = "custom.width"; value = 100; }
          ])
        ];
      })
      (table {
        id = 5;
        title = "Coverage";
        description =
          "`Dated` is what decides whether 'what is due Thursday' can be "
          + "answered at all. Points arrive only once something is graded.";
        gridPos = gridPos 7 24 0 13;
        sql = ''
          SELECT ch.display_name AS "Child",
                 count(*) AS "Known",
                 count(*) FILTER (WHERE a.due_at IS NOT NULL) AS "Dated",
                 count(*) FILTER (WHERE a.points_possible IS NOT NULL) AS "Pointed",
                 count(*) FILTER (WHERE a.due_at > now()) AS "Still ahead"
          FROM assignments a
          JOIN courses c ON c.id = a.course_id
          JOIN children ch ON ch.id = c.child_id
          WHERE c.active AND ch.display_name IN (''${child:sqlstring})
          GROUP BY ch.display_name
          ORDER BY ch.display_name
        '';
      })
    ];
  };

  healthJson = pkgs.writeText "schoolhouse-health.json" (builtins.toJSON health);
  queueJson = pkgs.writeText "schoolhouse-queue.json" (builtins.toJSON queue);
  gradesJson = pkgs.writeText "schoolhouse-grades.json" (builtins.toJSON grades);
  workJson = pkgs.writeText "schoolhouse-work.json" (builtins.toJSON work);
in
pkgs.runCommand "schoolhouse-grafana-dashboards"
{
  passthru.dashboardDefinitions = { inherit health queue grades work; };
} ''
  mkdir -p "$out"
  cp ${healthJson} "$out/sync-health.json"
  cp ${queueJson} "$out/review-queue.json"
  cp ${gradesJson} "$out/grades.json"
  cp ${workJson} "$out/work.json"
''
