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

  dashboard = { title, uid, description, panels, refresh ? "5m" }: {
    inherit title uid description panels refresh;
    annotations.list = [ ];
    editable = false;
    graphTooltip = 1;
    schemaVersion = 39;
    tags = [ "schoolhouse" "household" ];
    templating.list = [ ];
    time = { from = "now-30d"; to = "now"; };
    timezone = "America/New_York";
    weekStart = "";
  };

  # ── ingest health ───────────────────────────────────────────────────
  health = dashboard {
    title = "Schoolhouse — Ingest health";
    uid = "schoolhouse-health";
    description =
      "Whether the scraper is reading everything it fetches. `partial` is the "
      + "normal steady state, not an error: it means at least one page carried "
      + "something the parsers declined to guess at.";
    panels = [
      {
        id = 1;
        type = "stat";
        title = "Last run";
        description = "Age of the most recent scraper run. The timer is 7am and 4pm on weekdays, so anything past ~18h is stale.";
        datasource = datasource;
        gridPos = gridPos 4 6 0 0;
        targets = [
          (query {
            format = "table";
            sql = ''
              SELECT EXTRACT(EPOCH FROM now() - max(finished_at)) / 3600 AS "Hours"
              FROM ingest_runs WHERE source = 'scraper' AND finished_at IS NOT NULL
            '';
          })
        ];
        fieldConfig = {
          defaults = {
            unit = "h";
            decimals = 1;
            color.mode = "thresholds";
            thresholds = {
              mode = "absolute";
              steps = [
                { color = colors.green; value = null; }
                { color = colors.amber; value = 18; }
                { color = colors.red; value = 36; }
              ];
            };
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
      }
      {
        id = 2;
        type = "stat";
        title = "Open gaps";
        description = "Distinct things the parsers could not read. NOT the same as `parsers_pending`, which counts payloads and runs several times higher.";
        datasource = datasource;
        gridPos = gridPos 4 6 6 0;
        targets = [
          (query {
            format = "table";
            sql = ''SELECT count(*)::int AS "Gaps" FROM open_parser_gaps'';
          })
        ];
        fieldConfig = {
          defaults = {
            color.mode = "thresholds";
            thresholds = {
              mode = "absolute";
              steps = [
                { color = colors.green; value = null; }
                { color = colors.amber; value = 1; }
                { color = colors.red; value = 15; }
              ];
            };
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
      }
      {
        id = 3;
        type = "stat";
        title = "Needs a person";
        description = "Gaps whose `actionable` flag is true. A gap waiting on a date that has not arrived is excluded — there is genuinely nothing to learn from it yet.";
        datasource = datasource;
        gridPos = gridPos 4 6 12 0;
        targets = [
          (query {
            format = "table";
            sql = ''SELECT count(*)::int AS "Actionable" FROM open_parser_gaps WHERE actionable'';
          })
        ];
        fieldConfig = {
          defaults = {
            color.mode = "thresholds";
            thresholds = {
              mode = "absolute";
              steps = [
                { color = colors.green; value = null; }
                { color = colors.amber; value = 1; }
              ];
            };
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
      }
      {
        id = 4;
        type = "stat";
        title = "Held back last run";
        description = "Payloads whose records were discarded because the parser could not trust them. Zero is the goal and the normal state.";
        datasource = datasource;
        gridPos = gridPos 4 6 18 0;
        targets = [
          (query {
            format = "table";
            sql = ''
              SELECT parsers_pending::int AS "Pending"
              FROM ingest_runs WHERE source = 'scraper'
              ORDER BY id DESC LIMIT 1
            '';
          })
        ];
        fieldConfig = {
          defaults = {
            color.mode = "thresholds";
            thresholds = {
              mode = "absolute";
              steps = [
                { color = colors.green; value = null; }
                { color = colors.red; value = 1; }
              ];
            };
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
      }
      {
        id = 5;
        type = "timeseries";
        title = "What each run saw";
        description =
          "`records_seen` counts normalized records from batches that were "
          + "trusted. A drop with no page drop means a parser started refusing "
          + "something — which is the signal, not a fault.";
        datasource = datasource;
        gridPos = gridPos 8 12 0 4;
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
      {
        id = 6;
        type = "timeseries";
        title = "Gaps over time";
        description = "Open gaps per run against payloads held back. The two move independently on purpose.";
        datasource = datasource;
        gridPos = gridPos 8 12 12 4;
        targets = [
          (query {
            sql = ''
              SELECT finished_at AS time,
                     open_gaps::double precision AS "Open gaps",
                     parsers_pending::double precision AS "Held back"
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
            custom = timeSeriesCustom { fillOpacity = 18; };
            thresholds = noThresholds;
          };
          overrides = [
            (fieldOverride "Open gaps" [{
              id = "color";
              value = { fixedColor = colors.amber; mode = "fixed"; };
            }])
            (fieldOverride "Held back" [{
              id = "color";
              value = { fixedColor = colors.red; mode = "fixed"; };
            }])
          ];
        };
        options = timeSeriesOptions;
      }
      {
        id = 7;
        type = "table";
        title = "The queue";
        description =
          "Worst first. `affects` is the answer a gap qualifies, so a row here "
          + "means that answer may be incomplete. `seen` is how many runs it has "
          + "survived — a high count on a low severity is usually a shape nobody "
          + "has decided about yet, not neglect.";
        datasource = datasource;
        gridPos = gridPos 10 24 0 12;
        targets = [
          (query {
            format = "table";
            sql = ''
              SELECT severity AS "Sev",
                     affects AS "Affects",
                     COALESCE(child_name, 'all children') AS "Child",
                     COALESCE(course_title, NULLIF(section_id, '''), ''') AS "Course",
                     kind AS "Page",
                     reason AS "Reason",
                     times_seen AS "Seen",
                     actionable AS "Actionable",
                     detail::text AS "Evidence"
              FROM open_parser_gaps
              ORDER BY severity, last_seen_at DESC
            '';
          })
        ];
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
          overrides = [
            (fieldOverride "Sev" [
              {
                id = "custom.cellOptions";
                value = { type = "color-background"; mode = "gradient"; };
              }
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
            (fieldOverride "Evidence" [{ id = "custom.width"; value = 380; }])
          ];
        };
        options = tableOptions // {
          sortBy = [{ desc = false; displayName = "Sev"; }];
        };
      }
    ];
  };

  # ── what the store actually knows ───────────────────────────────────
  school = dashboard {
    title = "Schoolhouse — Coverage and grades";
    uid = "schoolhouse-school";
    description =
      "What the store holds per child. Coverage matters as much as the numbers: "
      + "an assignment with no due date cannot be placed in a week, and for a "
      + "long time most of them had none.";
    panels = [
      {
        id = 1;
        type = "table";
        title = "Coverage by child";
        description =
          "`Dated` is the one that decides whether 'what is due Thursday' can "
          + "be answered at all. Points arrive only once something is graded.";
        datasource = datasource;
        gridPos = gridPos 7 12 0 0;
        targets = [
          (query {
            format = "table";
            sql = ''
              SELECT ch.display_name AS "Child",
                     count(*) AS "Assignments",
                     count(*) FILTER (WHERE a.due_at IS NOT NULL) AS "Dated",
                     count(*) FILTER (WHERE a.points_possible IS NOT NULL) AS "Pointed",
                     count(*) FILTER (WHERE a.due_at > now()) AS "Still ahead"
              FROM assignments a
              JOIN courses c ON c.id = a.course_id
              JOIN children ch ON ch.id = c.child_id
              WHERE c.active
              GROUP BY ch.display_name
              ORDER BY ch.display_name
            '';
          })
        ];
        fieldConfig = {
          defaults = {
            custom = { align = "auto"; cellOptions.type = "auto"; filterable = false; inspect = false; };
            thresholds = noThresholds;
          };
          overrides = [ ];
        };
        options = tableOptions;
      }
      {
        id = 2;
        type = "table";
        title = "Outstanding, by due date";
        description =
          "Work Schoology itself reports as not turned in. Lateness is NOT read "
          + "from the page — that endpoint labels work due in five days '4 days "
          + "overdue' — it is computed here from the due date.";
        datasource = datasource;
        gridPos = gridPos 7 12 12 0;
        targets = [
          (query {
            format = "table";
            sql = ''
              SELECT ch.display_name AS "Child",
                     c.title AS "Course",
                     a.title AS "Work",
                     a.due_at AT TIME ZONE 'America/New_York' AS "Due",
                     CASE WHEN a.due_at < now() THEN 'late' ELSE 'ahead' END AS "State"
              FROM assignments a
              JOIN courses c ON c.id = a.course_id
              JOIN children ch ON ch.id = c.child_id
              JOIN latest_assignment_state s ON s.assignment_id = a.id
              WHERE s.status = 'assigned' AND a.due_at IS NOT NULL AND c.active
              ORDER BY a.due_at
            '';
          })
        ];
        fieldConfig = {
          defaults = {
            custom = { align = "auto"; cellOptions.type = "auto"; filterable = true; inspect = false; };
            thresholds = noThresholds;
          };
          overrides = [
            (fieldOverride "State" [{
              id = "mappings";
              value = [{
                type = "value";
                options = {
                  late = { color = colors.red; index = 0; text = "late"; };
                  ahead = { color = colors.green; index = 1; text = "ahead"; };
                };
              }];
            }])
          ];
        };
        options = tableOptions;
      }
      {
        id = 3;
        type = "timeseries";
        title = "Course grades over the term";
        description =
          "`course_grades` is append-only and only appends on change, so this is "
          + "real history rather than a resampled snapshot. Letter-only grades "
          + "carry no percentage and do not appear here.";
        datasource = datasource;
        gridPos = gridPos 10 24 0 7;
        targets = [
          (query {
            sql = ''
              SELECT g.observed_at AS time,
                     g.percent::double precision AS value,
                     ch.display_name || ' · ' || c.title AS metric
              FROM course_grades g
              JOIN courses c ON c.id = g.course_id
              JOIN children ch ON ch.id = c.child_id
              WHERE g.percent IS NOT NULL AND $__timeFilter(g.observed_at)
              ORDER BY g.observed_at
            '';
          })
        ];
        fieldConfig = {
          defaults = {
            unit = "percent";
            min = 0;
            max = 100;
            color.mode = "palette-classic";
            custom = timeSeriesCustom { fillOpacity = 0; showPoints = "always"; };
            thresholds = noThresholds;
          };
          overrides = [ ];
        };
        options = timeSeriesOptions;
      }
      {
        id = 4;
        type = "table";
        title = "Where each course stands";
        description = "The latest observation per course and marking period, including letter-only grades.";
        datasource = datasource;
        gridPos = gridPos 9 24 0 17;
        targets = [
          (query {
            format = "table";
            sql = ''
              SELECT ch.display_name AS "Child",
                     c.title AS "Course",
                     COALESCE(NULLIF(c.period, '''), '—') AS "Period",
                     COALESCE(s.display_name, c.teacher) AS "Teacher",
                     g.grading_period AS "Term",
                     g.percent AS "Percent",
                     NULLIF(g.letter, ''') AS "Letter",
                     g.observed_at AT TIME ZONE 'America/New_York' AS "Observed"
              FROM latest_course_grade g
              JOIN courses c ON c.id = g.course_id
              JOIN children ch ON ch.id = c.child_id
              LEFT JOIN staff s ON s.schoology_uid = c.teacher_uid
              WHERE c.active
              ORDER BY ch.display_name, c.title
            '';
          })
        ];
        fieldConfig = {
          defaults = {
            custom = { align = "auto"; cellOptions.type = "auto"; filterable = true; inspect = false; };
            thresholds = noThresholds;
          };
          overrides = [
            (fieldOverride "Percent" [
              { id = "unit"; value = "percent"; }
              { id = "decimals"; value = 1; }
              {
                id = "custom.cellOptions";
                value = { type = "color-text"; };
              }
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
          ];
        };
        options = tableOptions;
      }
    ];
  };

  healthJson = pkgs.writeText "schoolhouse-health.json" (builtins.toJSON health);
  schoolJson = pkgs.writeText "schoolhouse-school.json" (builtins.toJSON school);
in
pkgs.runCommand "schoolhouse-grafana-dashboards"
{
  passthru.dashboardDefinitions = { inherit health school; };
} ''
  mkdir -p "$out"
  cp ${healthJson} "$out/ingest-health.json"
  cp ${schoolJson} "$out/coverage-and-grades.json"
''
