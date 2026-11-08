{ pkgs }:

let
  datasource = {
    type = "grafana-postgresql-datasource";
    uid = "household-finance";
  };

  # Sure-inspired finance palette. See the attestation next to the datasource
  # contribution in homelab-mcp.nix.
  colors = {
    green = "#078C52";
    amber = "#F79009";
    red = "#F13636";
    blue = "#2E90FA";
    gray = "#737373";
  };

  query =
    { sql
    , refId ? "A"
    , format ? "time_series"
    , hide ? false
    }:
    {
      inherit datasource format hide refId;
      editorMode = "code";
      rawQuery = true;
      rawSql = sql;
    };

  gridPos = h: w: x: y: { inherit h w x y; };

  fieldOverride = name: properties: {
    matcher = {
      id = "byName";
      options = name;
    };
    inherit properties;
  };

  timeSeriesDefaults =
    { fillOpacity ? 18
    , drawStyle ? "line"
    , stackingMode ? "none"
    , unit ? "currencyUSD"
    , lineInterpolation ? "smooth"
    , showPoints ? "never"
    }:
    {
      color.mode = "palette-classic";
      custom = {
        axisCenteredZero = false;
        axisColorMode = "text";
        axisLabel = "";
        axisPlacement = "auto";
        barAlignment = 0;
        drawStyle = drawStyle;
        fillOpacity = fillOpacity;
        gradientMode = "none";
        hideFrom = {
          legend = false;
          tooltip = false;
          viz = false;
        };
        lineInterpolation = lineInterpolation;
        lineWidth = 2;
        pointSize = 5;
        scaleDistribution.type = "linear";
        showPoints = showPoints;
        spanNulls = false;
        stacking = {
          group = "A";
          mode = stackingMode;
        };
        thresholdsStyle.mode = "off";
      };
      mappings = [ ];
      thresholds = {
        mode = "absolute";
        steps = [{ color = "green"; value = null; }];
      };
      unit = unit;
    };

  timeSeriesOptions = {
    legend = {
      calcs = [ ];
      displayMode = "list";
      placement = "bottom";
      showLegend = true;
    };
    tooltip = {
      hideZeros = false;
      mode = "multi";
      sort = "desc";
    };
  };

  # Shared table shape. Every table in the suite is plain: no cell coloring,
  # no thresholds. Deliberate — a colored delta pre-decides what matters, and
  # deciding is the sentinel's job, not the glass's.
  tableFieldDefaults = {
    custom = {
      align = "auto";
      cellOptions.type = "auto";
      inspect = false;
    };
    mappings = [ ];
  };

  tableOptions = {
    cellHeight = "sm";
    footer = {
      countRows = false;
      fields = "";
      reducer = [ "sum" ];
      show = false;
    };
    showHeader = true;
  };

  # A scalar from household_finance.config_values drawn as a flat reference
  # line across the visible range. Two endpoints is all a horizontal line
  # needs, and anchoring them to $__timeFrom/$__timeTo makes the line span
  # exactly what the user is looking at.
  #
  # The absence contract matters more than the presence one: config_values is
  # written by a different exporter pass than the projection tables, so a name
  # can legitimately be missing. A missing row yields zero rows, the series
  # never materializes, and the panel simply draws no line. It must never
  # error, so there is no aggregate, no division, and no join against the
  # projection tables here — nothing that could turn "absent" into "broken".
  configLine =
    { name
    , series
    , refId
    }:
    query {
      inherit refId;
      sql = ''
        SELECT $__timeFrom()::timestamptz AS time, value::double precision AS "${series}"
        FROM household_finance.config_values
        WHERE name = '${name}'
        UNION ALL
        SELECT $__timeTo()::timestamptz, value::double precision
        FROM household_finance.config_values
        WHERE name = '${name}'
        ORDER BY time
      '';
    };

  # Styles a configLine series as a dashed reference rule. Forces drawStyle
  # and stacking explicitly so the line survives being dropped onto a panel
  # whose defaults are stacked bars.
  referenceLineOverride = series: color: fieldOverride series [
    { id = "color"; value = { fixedColor = color; mode = "fixed"; }; }
    { id = "custom.drawStyle"; value = "line"; }
    { id = "custom.lineStyle"; value = { dash = [ 10 10 ]; fill = "dash"; }; }
    { id = "custom.lineWidth"; value = 1; }
    { id = "custom.fillOpacity"; value = 0; }
    { id = "custom.stacking"; value = { group = "A"; mode = "none"; }; }
    { id = "custom.hideFrom"; value = { legend = false; tooltip = false; viz = false; }; }
  ];

  # Month-over-month movers. Compares the two most recent COMPLETE calendar
  # months inside the selected range; the in-progress month is excluded
  # because a partial month always reads as a collapse.
  #
  # If the range does not contain two complete months the comparison CTE
  # yields no rows and the table is empty. That is on purpose: falling back to
  # "prior = 0" would render every category as brand new, which is a lie.
  moversQuery =
    { table
    , keyColumn
    , keyLabel
    , limit ? null
    }:
    query {
      format = "table";
      sql = ''
        WITH complete_months AS (
          SELECT DISTINCT month
          FROM household_finance.${table}
          WHERE $__timeFilter(month::timestamp)
            AND month < date_trunc('month', current_date)::date
        ),
        ranked AS (
          SELECT month, row_number() OVER (ORDER BY month DESC) AS rn
          FROM complete_months
        ),
        comparison AS (
          SELECT cur_month, pri_month
          FROM (
            SELECT
              (SELECT month FROM ranked WHERE rn = 1) AS cur_month,
              (SELECT month FROM ranked WHERE rn = 2) AS pri_month
          ) AS pair
          WHERE cur_month IS NOT NULL AND pri_month IS NOT NULL
        ),
        cur AS (
          SELECT source.${keyColumn}, source.amount
          FROM household_finance.${table} AS source
          JOIN comparison ON source.month = comparison.cur_month
        ),
        pri AS (
          SELECT source.${keyColumn}, source.amount
          FROM household_finance.${table} AS source
          JOIN comparison ON source.month = comparison.pri_month
        )
        SELECT
          ${keyColumn} AS "${keyLabel}",
          coalesce(pri.amount, 0)::double precision AS "Prior",
          coalesce(cur.amount, 0)::double precision AS "Current",
          (coalesce(cur.amount, 0) - coalesce(pri.amount, 0))::double precision AS "Delta"
        FROM cur
        FULL JOIN pri USING (${keyColumn})
        ORDER BY abs(coalesce(cur.amount, 0) - coalesce(pri.amount, 0)) DESC
        ${if limit == null then "" else "LIMIT ${toString limit}"}
      '';
    };

  moversOverrides = [
    (fieldOverride "Prior" [{ id = "unit"; value = "currencyUSD"; }])
    (fieldOverride "Current" [{ id = "unit"; value = "currencyUSD"; }])
    (fieldOverride "Delta" [{ id = "unit"; value = "currencyUSD"; }])
  ];

  asOfPanel = id: {
    inherit id;
    type = "stat";
    title = "Nightly snapshot";
    description = "Rows are nightly projections. Intraday balances may legitimately differ from the source tools.";
    datasource = datasource;
    gridPos = gridPos 2 24 0 0;
    transparent = true;
    pluginVersion = "12.3.6";
    targets = [
      (query {
        format = "table";
        sql = ''
          SELECT extract(epoch FROM max(finished_at)) * 1000 AS "As of"
          FROM household_finance.export_runs
          WHERE ok
        '';
      })
    ];
    fieldConfig = {
      defaults = {
        color = {
          fixedColor = colors.green;
          mode = "fixed";
        };
        mappings = [ ];
        thresholds = {
          mode = "absolute";
          steps = [{ color = colors.green; value = null; }];
        };
        unit = "dateTimeAsIso";
      };
      overrides = [ ];
    };
    options = {
      colorMode = "none";
      graphMode = "none";
      justifyMode = "center";
      orientation = "horizontal";
      reduceOptions = {
        calcs = [ "lastNotNull" ];
        fields = "";
        values = false;
      };
      showPercentChange = false;
      textMode = "value_and_name";
      wideLayout = true;
    };
  };

  financeEventsAnnotation = {
    datasource = datasource;
    enable = true;
    hide = false;
    iconColor = colors.amber;
    name = "Household finance events";
    target = {
      inherit datasource;
      format = "table";
      rawQuery = true;
      rawSql = ''
        SELECT
          date::timestamp AT TIME ZONE 'America/New_York' AS time,
          CASE
            WHEN amount IS NULL THEN label
            ELSE label || ' (' || to_char(amount, 'FM$999,999,999,990.00') || ')'
          END AS text,
          type AS tags
        FROM household_finance.events
        WHERE $__timeFilter(date::timestamp)
        ORDER BY date
      '';
      refId = "FinanceEvents";
    };
  };

  navLinks = [
    {
      asDropdown = false;
      icon = "external link";
      includeVars = false;
      keepTime = true;
      targetBlank = false;
      title = "Overview";
      tooltip = "Household finance overview";
      type = "link";
      url = "/d/household-finance-overview";
    }
    {
      asDropdown = false;
      icon = "external link";
      includeVars = false;
      keepTime = true;
      targetBlank = false;
      title = "Cashflow & Categories";
      tooltip = "Household cashflow and categories";
      type = "link";
      url = "/d/household-finance-cashflow";
    }
    {
      asDropdown = false;
      icon = "external link";
      includeVars = false;
      keepTime = true;
      targetBlank = false;
      title = "Debt & Projects";
      tooltip = "Household debt and projects";
      type = "link";
      url = "/d/household-finance-debt";
    }
    {
      asDropdown = false;
      icon = "external link";
      includeVars = false;
      keepTime = true;
      targetBlank = false;
      title = "Data Health";
      tooltip = "Whether the other three can be trusted";
      type = "link";
      url = "/d/household-finance-health";
    }
  ];

  dashboard =
    { title
    , uid
    , panels
    , annotations ? [ ]
    , timeFrom ? "now-2y"
    , timeTo ? "now"
    }:
    {
      id = null;
      inherit panels title uid;
      annotations.list = annotations;
      description = "Household finance projection. Glass, never plumbing; alerts and required actions remain in the sentinel. Visual treatment references Sure (github.com/we-promise/sure).";
      editable = true;
      fiscalYearStartMonth = 0;
      graphTooltip = 1;
      links = navLinks;
      liveNow = false;
      preload = false;
      refresh = "1h";
      schemaVersion = 41;
      tags = [ "household-finance" "nightly-projection" "glass-not-plumbing" ];
      templating.list = [ ];
      time = {
        from = timeFrom;
        to = timeTo;
      };
      timepicker = {
        refresh_intervals = [ "5m" "15m" "30m" "1h" ];
        time_options = [ "6M" "1y" "2y" "5y" ];
      };
      timezone = "America/New_York";
      version = 1;
      weekStart = "";
    };

  overview = dashboard {
    title = "Household Finance · Overview";
    uid = "household-finance-overview";
    annotations = [ financeEventsAnnotation ];
    timeTo = "now+30d";
    panels = [
      (asOfPanel 1)
      {
        id = 2;
        type = "timeseries";
        title = "Net worth";
        description = "Daily net worth, with governance events from household_finance.events.";
        datasource = datasource;
        gridPos = gridPos 10 16 0 2;
        pluginVersion = "12.3.6";
        targets = [
          (query {
            sql = ''
              SELECT date::timestamp AT TIME ZONE 'America/New_York' AS time, net::double precision AS "Net worth"
              FROM household_finance.net_worth_daily
              WHERE $__timeFilter(date::timestamp)
              ORDER BY date
            '';
          })
        ];
        fieldConfig = {
          defaults = timeSeriesDefaults { fillOpacity = 10; };
          overrides = [
            (fieldOverride "Net worth" [{
              id = "color";
              value = { fixedColor = colors.green; mode = "fixed"; };
            }])
          ];
        };
        options = timeSeriesOptions;
      }
      {
        id = 3;
        type = "timeseries";
        title = "Assets vs liabilities";
        description = "Liabilities are displayed as a positive magnitude; the source remains signed.";
        datasource = datasource;
        gridPos = gridPos 10 8 16 2;
        pluginVersion = "12.3.6";
        targets = [
          (query {
            sql = ''
              SELECT
                date::timestamp AT TIME ZONE 'America/New_York' AS time,
                assets::double precision AS "Assets",
                abs(liabilities)::double precision AS "Liabilities"
              FROM household_finance.net_worth_daily
              WHERE $__timeFilter(date::timestamp)
              ORDER BY date
            '';
          })
        ];
        fieldConfig = {
          defaults = timeSeriesDefaults {
            fillOpacity = 45;
            stackingMode = "normal";
          };
          overrides = [
            (fieldOverride "Assets" [{
              id = "color";
              value = { fixedColor = colors.green; mode = "fixed"; };
            }])
            (fieldOverride "Liabilities" [{
              id = "color";
              value = { fixedColor = colors.amber; mode = "fixed"; };
            }])
          ];
        };
        options = timeSeriesOptions;
      }
      {
        id = 4;
        type = "table";
        title = "Account balances";
        description = "One row per account with a Grafana 12 timeSeriesTable sparkline and current projected balance.";
        datasource = datasource;
        gridPos = gridPos 12 24 0 12;
        pluginVersion = "12.3.6";
        targets = [
          (query {
            sql = ''
              SELECT
                date::timestamp AT TIME ZONE 'America/New_York' AS time,
                balance::double precision AS "Balance",
                account AS account
              FROM household_finance.account_balances_daily
              WHERE $__timeFilter(date::timestamp)
              ORDER BY date, account
            '';
          })
        ];
        transformations = [{
          id = "timeSeriesTable";
          options.A.timeField = "Time";
        }];
        fieldConfig = {
          defaults = {
            color = {
              fixedColor = colors.blue;
              mode = "shades";
            };
            custom = {
              align = "auto";
              cellOptions = {
                drawStyle = "line";
                type = "sparkline";
              };
              inspect = false;
            };
            mappings = [ ];
            thresholds = {
              mode = "absolute";
              steps = [{ color = colors.blue; value = null; }];
            };
            unit = "currencyUSD";
          };
          overrides = [
            (fieldOverride "account" [
              { id = "displayName"; value = "Account"; }
              { id = "custom.cellOptions"; value = { type = "auto"; }; }
              { id = "custom.width"; value = 260; }
              { id = "unit"; value = "none"; }
            ])
            (fieldOverride "Trend #A" [
              { id = "displayName"; value = "Balance"; }
            ])
          ];
        };
        options = {
          cellHeight = "sm";
          footer = {
            countRows = false;
            fields = "";
            reducer = [ "sum" ];
            show = false;
          };
          showHeader = true;
        };
      }
    ];
  };

  cashflow = dashboard {
    title = "Household Finance · Cashflow & Categories";
    uid = "household-finance-cashflow";
    panels = [
      (asOfPanel 1)
      {
        id = 2;
        type = "barchart";
        title = "Monthly income vs expense";
        description = "Categorized on-budget income compared with positive household spend; account setup, transfers, and card-payment plumbing are excluded upstream.";
        datasource = datasource;
        gridPos = gridPos 8 12 0 2;
        pluginVersion = "12.3.6";
        targets = [
          (query {
            format = "table";
            sql = ''
              WITH expenses AS (
                SELECT month, sum(amount) AS expense
                FROM household_finance.category_monthly
                GROUP BY month
              ),
              monthly AS (
                SELECT
                  coalesce(income.month, expenses.month) AS month,
                  coalesce(income.income, 0) AS income,
                  coalesce(expenses.expense, 0) AS expense
                FROM household_finance.income_monthly AS income
                FULL JOIN expenses USING (month)
              )
              SELECT
                to_char(month, 'Mon YY') AS "Month",
                income::double precision AS "Income",
                expense::double precision AS "Expense"
              FROM monthly
              WHERE $__timeFilter(month::timestamp)
              ORDER BY month
            '';
          })
        ];
        fieldConfig = {
          defaults = {
            color.mode = "palette-classic";
            custom = {
              axisBorderShow = false;
              axisCenteredZero = false;
              axisColorMode = "text";
              axisGridShow = true;
              axisLabel = "";
              axisPlacement = "auto";
              fillOpacity = 85;
              gradientMode = "none";
              hideFrom = {
                legend = false;
                tooltip = false;
                viz = false;
              };
              lineWidth = 1;
              scaleDistribution.type = "linear";
              thresholdsStyle.mode = "off";
            };
            mappings = [ ];
            thresholds = {
              mode = "absolute";
              steps = [{ color = colors.green; value = null; }];
            };
            unit = "currencyUSD";
          };
          overrides = [
            (fieldOverride "Income" [{ id = "color"; value = { fixedColor = colors.green; mode = "fixed"; }; }])
            (fieldOverride "Expense" [{ id = "color"; value = { fixedColor = colors.red; mode = "fixed"; }; }])
          ];
        };
        options = {
          barRadius = 0.05;
          barWidth = 0.85;
          fullHighlight = false;
          groupWidth = 0.7;
          legend = {
            calcs = [ ];
            displayMode = "list";
            placement = "bottom";
            showLegend = true;
          };
          orientation = "auto";
          showValue = "never";
          stacking = "none";
          text = { };
          tooltip = {
            hideZeros = false;
            maxHeight = 600;
            mode = "multi";
            sort = "desc";
          };
          xField = "Month";
          xTickLabelRotation = -35;
          xTickLabelSpacing = 0;
        };
      }
      {
        id = 3;
        type = "timeseries";
        title = "Category trend";
        description = "The eight largest categories in the selected range; spend is positive money out.";
        datasource = datasource;
        gridPos = gridPos 8 12 12 2;
        pluginVersion = "12.3.6";
        targets = [
          (query {
            sql = ''
              WITH top_categories AS (
                SELECT category
                FROM household_finance.category_monthly
                WHERE $__timeFilter(month::timestamp)
                GROUP BY category
                ORDER BY sum(amount) DESC
                LIMIT 8
              )
              SELECT
                month::timestamp AT TIME ZONE 'America/New_York' AS time,
                amount::double precision AS value,
                category AS metric
              FROM household_finance.category_monthly
              WHERE $__timeFilter(month::timestamp)
                AND category IN (SELECT category FROM top_categories)
              ORDER BY month, category
            '';
          })
        ];
        fieldConfig = {
          defaults = timeSeriesDefaults { fillOpacity = 8; };
          overrides = [ ];
        };
        options = timeSeriesOptions;
      }
      {
        id = 4;
        type = "volkovlabs-echarts-panel";
        title = "Categorized spend flow";
        description = "A truthful outflow-to-category Sankey. It does not label the source as income until income_monthly is free of opening-balance activity.";
        datasource = datasource;
        gridPos = gridPos 11 16 0 10;
        pluginVersion = "7.2.2";
        targets = [
          (query {
            format = "table";
            sql = ''
              SELECT
                'Categorized spend' AS source,
                category AS target,
                sum(amount)::double precision AS value
              FROM household_finance.category_monthly
              WHERE $__timeFilter(month::timestamp)
              GROUP BY category
              ORDER BY value DESC
            '';
          })
        ];
        fieldConfig = {
          defaults = { };
          overrides = [ ];
        };
        options = {
          editorMode = "code";
          followTheme = true;
          getOption = ''
            const frame = context.panel.data.series[0];
            if (!frame) {
              return { title: { text: 'No categorized spend in this range', left: 'center', top: 'middle' } };
            }

            const field = (name) => frame.fields.find((item) => item.name.toLowerCase() === name);
            const sourceField = field('source');
            const targetField = field('target');
            const valueField = field('value');
            if (!sourceField || !targetField || !valueField) {
              return { title: { text: 'Expected source / target / value fields', left: 'center', top: 'middle' } };
            }

            const sources = Array.from(sourceField.values);
            const targets = Array.from(targetField.values);
            const values = Array.from(valueField.values);
            const links = sources.map((source, index) => ({
              source,
              target: targets[index],
              value: Number(values[index]),
            })).filter((link) => link.value > 0);
            const names = [...new Set(links.flatMap((link) => [link.source, link.target]))];
            const palette = ['#078C52', '#2E90FA', '#F79009', '#F13636', '#12B76A', '#175CD3', '#DC6803', '#737373'];
            const money = new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' });

            return {
              tooltip: {
                trigger: 'item',
                formatter: (item) => item.name + ': ' + money.format(Number(item.value || 0)),
              },
              series: [{
                type: 'sankey',
                data: names.map((name, index) => ({
                  name,
                  itemStyle: { color: name === 'Categorized spend' ? '#078C52' : palette[(index + 1) % palette.length] },
                })),
                links,
                emphasis: { focus: 'adjacency' },
                lineStyle: { color: 'gradient', curveness: 0.5, opacity: 0.45 },
                nodeAlign: 'justify',
                nodeGap: 12,
                nodeWidth: 18,
                label: { fontFamily: 'Geist, sans-serif', fontSize: 12 },
              }],
            };
          '';
          map = "none";
          renderer = "canvas";
        };
      }
      {
        id = 5;
        type = "timeseries";
        title = "Amazon spend by person";
        description = "Exact lading attribution remains separate from (unattributed); no charge is spread or dropped. The dashed rule is the configured AMAZON_BASELINE, a reference level rather than a limit; it is absent from the chart whenever it is absent from config_values.";
        datasource = datasource;
        gridPos = gridPos 11 8 16 10;
        pluginVersion = "12.3.6";
        targets = [
          (query {
            sql = ''
              SELECT
                month::timestamp AT TIME ZONE 'America/New_York' AS time,
                amazon_amount::double precision AS value,
                person AS metric
              FROM household_finance.person_monthly
              WHERE $__timeFilter(month::timestamp)
              ORDER BY month, person
            '';
          })
          (configLine {
            name = "AMAZON_BASELINE";
            series = "Baseline";
            refId = "B";
          })
        ];
        fieldConfig = {
          defaults = timeSeriesDefaults {
            drawStyle = "bars";
            fillOpacity = 75;
            stackingMode = "normal";
          };
          overrides = [
            (fieldOverride "ryan" [{ id = "color"; value = { fixedColor = colors.green; mode = "fixed"; }; }])
            (fieldOverride "steffi" [{ id = "color"; value = { fixedColor = colors.blue; mode = "fixed"; }; }])
            (fieldOverride "(unattributed)" [{ id = "color"; value = { fixedColor = colors.amber; mode = "fixed"; }; }])
            # Gray, not red. The baseline is a descriptive monthly average, so
            # it gets the same neutral treatment as "Monthly floor" on the
            # debt dashboard. Colouring it as a limit would imply a breach the
            # projection is not entitled to declare.
            (referenceLineOverride "Baseline" colors.gray)
          ];
        };
        options = timeSeriesOptions;
      }
      {
        id = 6;
        type = "table";
        title = "Top merchants";
        description = "Payee-level spend from the same filtered population as category_monthly; credit-card payment plumbing is excluded upstream.";
        datasource = datasource;
        gridPos = gridPos 7 24 0 21;
        pluginVersion = "12.3.6";
        targets = [
          (query {
            format = "table";
            sql = ''
              SELECT
                payee AS "Merchant",
                sum(amount) AS "Spend",
                sum(txn_count) AS "Transactions",
                count(DISTINCT month) AS "Months"
              FROM household_finance.merchant_monthly
              WHERE $__timeFilter(month::timestamp)
              GROUP BY payee
              ORDER BY "Spend" DESC
              LIMIT 20
            '';
          })
        ];
        fieldConfig = {
          defaults = tableFieldDefaults;
          overrides = [
            (fieldOverride "Spend" [{ id = "unit"; value = "currencyUSD"; }])
          ];
        };
        options = tableOptions;
      }
      {
        id = 7;
        type = "table";
        title = "Top movers · categories";
        description = "Needs two complete months in range: with fewer, this panel is deliberately empty rather than wrong. Month-over-month change for every category, largest absolute move first, comparing the two most recent complete months; the in-progress month is excluded, and a missing prior month is never treated as zero — that would render an ordinary month as entirely new spending. Unranked and uncoloured on purpose: it reports what moved, it does not judge which moves matter.";
        datasource = datasource;
        gridPos = gridPos 9 8 0 28;
        pluginVersion = "12.3.6";
        targets = [
          (moversQuery {
            table = "category_monthly";
            keyColumn = "category";
            keyLabel = "Category";
          })
        ];
        fieldConfig = {
          defaults = tableFieldDefaults;
          overrides = moversOverrides;
        };
        options = tableOptions;
      }
      {
        id = 8;
        type = "table";
        title = "Top movers · merchants";
        description = "Needs two complete months in range, same as the category panel, and is empty otherwise. The same comparison at payee level, capped at the 25 largest absolute moves. A payee that merely got renamed upstream appears twice, once falling to zero and once rising from it; that pairing is left visible rather than smoothed away.";
        datasource = datasource;
        gridPos = gridPos 9 8 8 28;
        pluginVersion = "12.3.6";
        targets = [
          (moversQuery {
            table = "merchant_monthly";
            keyColumn = "payee";
            keyLabel = "Merchant";
            limit = 25;
          })
        ];
        fieldConfig = {
          defaults = tableFieldDefaults;
          overrides = moversOverrides;
        };
        options = tableOptions;
      }
      {
        id = 9;
        type = "table";
        title = "New merchants";
        description = "Needs one complete month in range, and is empty otherwise. Payees whose first appearance anywhere in merchant_monthly is the same complete month the movers panels compare, with more than $100 of spend. First-seen is computed over all history, not the selected range, so widening or narrowing the time picker cannot manufacture a new merchant.";
        datasource = datasource;
        gridPos = gridPos 9 8 16 28;
        pluginVersion = "12.3.6";
        targets = [
          (query {
            format = "table";
            sql = ''
              WITH complete_months AS (
                SELECT DISTINCT month
                FROM household_finance.merchant_monthly
                WHERE $__timeFilter(month::timestamp)
                  AND month < date_trunc('month', current_date)::date
              ),
              current_month AS (
                SELECT max(month) AS month FROM complete_months
              ),
              first_seen AS (
                SELECT payee, min(month) AS first_month
                FROM household_finance.merchant_monthly
                GROUP BY payee
              )
              SELECT
                merchant.payee AS "Merchant",
                merchant.amount::double precision AS "Spend",
                merchant.txn_count AS "Transactions"
              FROM household_finance.merchant_monthly AS merchant
              JOIN current_month ON merchant.month = current_month.month
              JOIN first_seen
                ON first_seen.payee = merchant.payee
                AND first_seen.first_month = current_month.month
              WHERE merchant.amount > 100
              ORDER BY merchant.amount DESC
            '';
          })
        ];
        fieldConfig = {
          defaults = tableFieldDefaults;
          overrides = [
            (fieldOverride "Spend" [{ id = "unit"; value = "currencyUSD"; }])
          ];
        };
        options = tableOptions;
      }
    ];
  };

  debt = dashboard {
    title = "Household Finance · Debt & Projects";
    uid = "household-finance-debt";
    annotations = [ financeEventsAnnotation ];
    timeTo = "now+2y";
    panels = [
      (asOfPanel 1)
      {
        id = 2;
        type = "timeseries";
        title = "HELOC burn-down and projection";
        description = "Projection uses the latest 120-day linear principal trend and stops at zero; it is descriptive, not a payment plan.";
        datasource = datasource;
        gridPos = gridPos 9 12 0 2;
        pluginVersion = "12.3.6";
        targets = [
          (query {
            sql = ''
              WITH actual AS (
                SELECT date, (-balance)::double precision AS owed
                FROM household_finance.debt_daily
                WHERE account = 'Spectra HELOC'
              ),
              bounds AS (
                SELECT max(date) AS max_date FROM actual
              ),
              recent AS (
                SELECT actual.*
                FROM actual, bounds
                WHERE actual.date >= bounds.max_date - 120
              ),
              trend AS (
                SELECT
                  regr_slope(owed, (date - DATE '2000-01-01')::double precision) AS slope,
                  max(date) AS max_date
                FROM recent
              ),
              anchor AS (
                SELECT actual.date, actual.owed, trend.slope
                FROM actual
                JOIN trend ON actual.date = trend.max_date
              ),
              projection AS (
                SELECT
                  projected.day::date AS date,
                  greatest(0::double precision, anchor.owed + anchor.slope * (projected.day::date - anchor.date)) AS owed
                FROM anchor
                CROSS JOIN LATERAL generate_series(
                  anchor.date + 1,
                  least(
                    anchor.date + 1095,
                    anchor.date + ceil(-anchor.owed / nullif(anchor.slope, 0))::integer
                  ),
                  interval '1 day'
                ) AS projected(day)
                WHERE anchor.slope < 0
              )
              SELECT date::timestamp AT TIME ZONE 'America/New_York' AS time, owed AS "Actual", NULL::double precision AS "Projection"
              FROM actual
              WHERE $__timeFilter(date::timestamp)
              UNION ALL
              SELECT date::timestamp AT TIME ZONE 'America/New_York' AS time, NULL::double precision AS "Actual", owed AS "Projection"
              FROM projection
              WHERE $__timeFilter(date::timestamp)
              ORDER BY time
            '';
          })
        ];
        fieldConfig = {
          defaults = timeSeriesDefaults { fillOpacity = 10; };
          overrides = [
            (fieldOverride "Actual" [{ id = "color"; value = { fixedColor = colors.red; mode = "fixed"; }; }])
            (fieldOverride "Projection" [
              { id = "color"; value = { fixedColor = colors.amber; mode = "fixed"; }; }
              { id = "custom.lineStyle"; value = { dash = [ 8 8 ]; fill = "dash"; }; }
            ])
          ];
        };
        options = timeSeriesOptions;
      }
      {
        id = 3;
        type = "timeseries";
        title = "All debt";
        description = "Configured debt accounts, shown as positive amounts owed and stacked by account.";
        datasource = datasource;
        gridPos = gridPos 9 12 12 2;
        pluginVersion = "12.3.6";
        targets = [
          (query {
            sql = ''
              SELECT
                date::timestamp AT TIME ZONE 'America/New_York' AS time,
                (-balance)::double precision AS value,
                account AS metric
              FROM household_finance.debt_daily
              WHERE $__timeFilter(date::timestamp)
              ORDER BY date, account
            '';
          })
        ];
        fieldConfig = {
          defaults = timeSeriesDefaults {
            fillOpacity = 55;
            stackingMode = "normal";
          };
          overrides = [ ];
        };
        options = timeSeriesOptions;
      }
      {
        id = 4;
        type = "timeseries";
        title = "Buffer history";
        description = "Newest point may use bank-available basis; historical points use the register. Events annotate breaches, bridges, strikes, and dated notes. The dashed rule is the configured BUFFER_FLOOR; it is absent from the chart whenever it is absent from config_values, and crossing it is described here but acted on nowhere.";
        datasource = datasource;
        gridPos = gridPos 9 16 0 11;
        pluginVersion = "12.3.6";
        targets = [
          (query {
            sql = ''
              SELECT
                date::timestamp AT TIME ZONE 'America/New_York' AS time,
                buffer::double precision AS "Buffer",
                checking_available::double precision AS "Checking available"
              FROM household_finance.buffer_daily
              WHERE $__timeFilter(date::timestamp)
              ORDER BY date
            '';
          })
          (configLine {
            name = "BUFFER_FLOOR";
            series = "Buffer floor";
            refId = "B";
          })
        ];
        fieldConfig = {
          defaults = timeSeriesDefaults { fillOpacity = 12; };
          overrides = [
            (fieldOverride "Buffer" [{ id = "color"; value = { fixedColor = colors.green; mode = "fixed"; }; }])
            (fieldOverride "Checking available" [{ id = "color"; value = { fixedColor = colors.blue; mode = "fixed"; }; }])
            # Red here, unlike the gray Amazon baseline, because BUFFER_FLOOR
            # is the one level in the suite the household has actually agreed
            # not to cross. Still only glass: the line describes the breach,
            # the sentinel is what notices it.
            (referenceLineOverride "Buffer floor" colors.red)
            # FLOOR is deliberately NOT overlaid on this panel. It is a
            # monthly *spending* floor; this chart is a checking *headroom*
            # level. Both are dollars, so a second line would happily draw and
            # would be read as comparable when it is not. FLOOR already has an
            # honest home on "Spend pace vs monthly floor" below.
          ];
        };
        options = timeSeriesOptions;
      }
      {
        id = 5;
        type = "bargauge";
        title = "Spend pace vs monthly floor";
        description = "Month-to-date categorized spend compared with linear pace and the full operational FLOOR exported for the same snapshot date.";
        datasource = datasource;
        gridPos = gridPos 9 8 16 11;
        pluginVersion = "12.3.6";
        targets = [
          (query {
            format = "table";
            sql = ''
              WITH configured AS (
                SELECT value::numeric AS monthly_floor, as_of
                FROM household_finance.config_values
                WHERE name = 'FLOOR'
              ),
              spend AS (
                SELECT coalesce(sum(monthly.amount), 0)::numeric AS spend_mtd
                FROM household_finance.category_monthly AS monthly
                CROSS JOIN configured
                WHERE monthly.month = date_trunc('month', configured.as_of)::date
              )
              SELECT
                spend.spend_mtd::double precision AS "Spend MTD",
                configured.monthly_floor
                  * extract(day FROM configured.as_of)
                  / extract(day FROM (date_trunc('month', configured.as_of) + interval '1 month - 1 day')) AS "Floor pace",
                configured.monthly_floor::double precision AS "Monthly floor"
              FROM spend CROSS JOIN configured
            '';
          })
        ];
        fieldConfig = {
          defaults = {
            color.mode = "palette-classic";
            mappings = [ ];
            min = 0;
            thresholds = {
              mode = "absolute";
              steps = [{ color = colors.green; value = null; }];
            };
            unit = "currencyUSD";
          };
          overrides = [
            (fieldOverride "Spend MTD" [{ id = "color"; value = { fixedColor = colors.blue; mode = "fixed"; }; }])
            (fieldOverride "Floor pace" [{ id = "color"; value = { fixedColor = colors.amber; mode = "fixed"; }; }])
            (fieldOverride "Monthly floor" [{ id = "color"; value = { fixedColor = colors.gray; mode = "fixed"; }; }])
          ];
        };
        options = {
          displayMode = "gradient";
          maxVizHeight = 300;
          minVizHeight = 16;
          minVizWidth = 8;
          namePlacement = "auto";
          orientation = "horizontal";
          reduceOptions = {
            calcs = [ "lastNotNull" ];
            fields = "";
            values = false;
          };
          showUnfilled = true;
          sizing = "auto";
          valueMode = "color";
        };
      }
      {
        id = 6;
        type = "table";
        title = "Project spend";
        description = "Transaction-level project shares parsed from [proj:<tag>=<amount>] notes; txn_ref traces each row to Actual.";
        datasource = datasource;
        gridPos = gridPos 8 13 0 20;
        pluginVersion = "12.3.6";
        targets = [
          (query {
            format = "table";
            sql = ''
              SELECT
                to_char(date, 'YYYY-MM-DD') AS "Date",
                proj_tag AS "Project",
                amount AS "Amount",
                txn_ref AS "Actual transaction"
              FROM household_finance.project_spend
              WHERE $__timeFilter(date::timestamp)
              ORDER BY date DESC, proj_tag
            '';
          })
        ];
        fieldConfig = {
          defaults = tableFieldDefaults;
          overrides = [
            (fieldOverride "Amount" [{ id = "unit"; value = "currencyUSD"; }])
          ];
        };
        options = tableOptions;
      }
      {
        id = 7;
        type = "timeseries";
        title = "Project cumulative";
        description = "Running total per proj_tag, one line per project. The running sum is taken from each project's first transaction, not from the start of the selected range, so panning the time picker never re-zeros a project mid-flight. Refunds carry mirrored negative shares by convention, so a curve stepping down is correct rather than a data fault; a project that nets to zero is a purchase and its return, both recorded. Steps are drawn square because nothing is known between transactions.";
        datasource = datasource;
        gridPos = gridPos 8 11 13 20;
        pluginVersion = "12.3.6";
        targets = [
          (query {
            sql = ''
              WITH daily AS (
                SELECT proj_tag, date, sum(amount) AS amount
                FROM household_finance.project_spend
                GROUP BY proj_tag, date
              ),
              cumulative AS (
                SELECT
                  proj_tag,
                  date,
                  sum(amount) OVER (PARTITION BY proj_tag ORDER BY date) AS running
                FROM daily
              )
              SELECT
                date::timestamp AT TIME ZONE 'America/New_York' AS time,
                running::double precision AS value,
                proj_tag AS metric
              FROM cumulative
              WHERE $__timeFilter(date::timestamp)
              -- Time first. Grafana's long-to-wide conversion rejects a frame
              -- that is not globally ascending by time, so grouping by
              -- proj_tag here would fail the panel outright.
              ORDER BY date, proj_tag
            '';
          })
        ];
        fieldConfig = {
          defaults = timeSeriesDefaults {
            fillOpacity = 0;
            # Square steps and visible points: project spend is a handful of
            # discrete transactions, and a smoothed curve would invent a
            # spending rate between them that never happened.
            lineInterpolation = "stepAfter";
            showPoints = "always";
          };
          overrides = [ ];
        };
        options = timeSeriesOptions;
      }
    ];
  };

  # ── the fourth dashboard: can the other three be trusted? ──────────
  #
  # The suite shows the money. It does not show the machinery, and the week
  # that prompted this board is the argument: a register drifting from the
  # bank while every transaction read as cleared, a bank feed five days dead,
  # an uncategorised wire sitting outside every spend chart. None of those is
  # visible on a net-worth line.
  #
  # THREE OF ITS FOUR TABLES START EMPTY, and every panel built on one says so
  # in its own description rather than leaving a reader to wonder why a line
  # begins mid-August. `reconcile_daily`, `sync_health_daily` and
  # `hygiene_daily` record what was OBSERVED on a given night — what the bank
  # reported, when a feed last fetched, what was still uncategorised — and the
  # register keeps no history of any of them. They cannot be backfilled, so
  # they accumulate one night at a time from the first run after deploy.
  #
  # Two panels here use colour, which the rest of the suite deliberately
  # avoids. That is not a threshold creeping in: both are state timelines
  # where the colour IS the value — a categorical state rendered as a band,
  # the way a status column is rendered as a word. There is still no alert,
  # no conditional cell colour, and nothing on this board decides anything.

  # A state timeline reads a NUMBER, not a string: Grafana's long-to-wide
  # conversion treats a text column as a label rather than a value, so a
  # status returned as text draws nothing at all. Every status is therefore
  # encoded to an integer in SQL and mapped back to its own word and colour
  # here — which also means an unrecognised status gets its own visible band
  # instead of being quietly folded in with the healthy ones.
  stateMapping = pairs: [{
    type = "value";
    options = builtins.listToAttrs (map
      (entry: {
        name = toString entry.value;
        value = {
          text = entry.text;
          color = entry.color;
          index = entry.value;
        };
      })
      pairs);
  }];

  stateTimelineDefaults = mappings: {
    color.mode = "thresholds";
    custom = {
      fillOpacity = 85;
      insertNulls = false;
      lineWidth = 0;
      spanNulls = false;
    };
    inherit mappings;
    # One step, so nothing is coloured by magnitude. The mappings above own
    # every colour on these panels; a threshold ladder here would silently
    # outrank them and turn a status code into a severity score.
    thresholds = {
      mode = "absolute";
      steps = [{ color = colors.gray; value = null; }];
    };
    unit = "none";
  };

  stateTimelineOptions = {
    alignValue = "left";
    legend = {
      displayMode = "list";
      placement = "bottom";
      showLegend = true;
    };
    mergeValues = true;
    rowHeight = 0.85;
    showValue = "never";
    tooltip = {
      hideZeros = false;
      mode = "single";
      sort = "none";
    };
  };

  dataHealth = dashboard {
    title = "Household Finance · Data Health";
    uid = "household-finance-health";
    # Deliberately NOT the suite's two-year default. Three of the four tables
    # behind this board begin accumulating on deploy day, so a two-year window
    # would open on a sliver of data at the far right edge and read as broken.
    # Ninety days is generous for those and shows a quarter of the recurring
    # grid, whose own panel says to widen the range for the full year.
    timeFrom = "now-90d";
    panels = [
      (asOfPanel 1)
      {
        id = 2;
        type = "timeseries";
        title = "Register vs bank drift";
        description = "Should hug zero; a persistent offset is a register error, not noise. One line per non-market account that has ever drifted in this range. Market-valued accounts are excluded because their drift is valuation, not error — the bank reports live value while the register moves only when a transaction posts. Accounts with no bank balance to compare against contribute no point rather than a zero. Recorded nightly and NOT backfillable: the bank does not keep yesterday's reported balance, so this line begins on the first export after deploy.";
        datasource = datasource;
        gridPos = gridPos 9 24 0 2;
        pluginVersion = "12.3.6";
        targets = [
          (query {
            sql = ''
              WITH ever_drifted AS (
                SELECT account
                FROM household_finance.reconcile_daily
                WHERE $__timeFilter(date::timestamp)
                  AND classification <> 'market_movement'
                GROUP BY account
                HAVING sum(abs(coalesce(drift, 0))) > 0
              )
              SELECT
                date::timestamp AT TIME ZONE 'America/New_York' AS time,
                drift::double precision AS value,
                account AS metric
              FROM household_finance.reconcile_daily
              WHERE $__timeFilter(date::timestamp)
                AND classification <> 'market_movement'
                AND drift IS NOT NULL
                AND account IN (SELECT account FROM ever_drifted)
              ORDER BY date, account
            '';
          })
        ];
        fieldConfig = {
          defaults = timeSeriesDefaults { fillOpacity = 0; };
          overrides = [ ];
        };
        options = timeSeriesOptions;
      }
      {
        id = 3;
        type = "state-timeline";
        title = "Bank feed status";
        description = "What Actual recorded on each account's last bank pull, one band per account. Green is a pull that succeeded; amber is transient and needs nobody (rate limit, timeout); red needs a person at SimpleFin Bridge. Grey means the account is not bank-linked. A status Actual invents that this panel does not know gets its own band rather than being folded in with the healthy ones. Informational, exactly as it is in finances_sync_status: the freshness verdict is feed AGE, not this. Recorded nightly and not backfillable.";
        datasource = datasource;
        gridPos = gridPos 8 12 0 11;
        pluginVersion = "12.3.6";
        targets = [
          (query {
            sql = ''
              SELECT
                date::timestamp AT TIME ZONE 'America/New_York' AS time,
                (CASE
                  WHEN bank_sync_status IS NULL THEN 7
                  WHEN bank_sync_status = 'ok' THEN 0
                  WHEN bank_sync_status = 'rate-limit-exceeded' THEN 1
                  WHEN bank_sync_status = 'timed-out' THEN 2
                  WHEN bank_sync_status = 'attention-required' THEN 3
                  WHEN bank_sync_status = 'reauth-required' THEN 4
                  WHEN bank_sync_status = 'account-missing' THEN 5
                  WHEN bank_sync_status = 'failed' THEN 6
                  ELSE 8
                END)::double precision AS value,
                account AS metric
              FROM household_finance.sync_health_daily
              WHERE $__timeFilter(date::timestamp)
              ORDER BY date, account
            '';
          })
        ];
        fieldConfig = {
          defaults = stateTimelineDefaults (stateMapping [
            { value = 0; text = "ok"; color = colors.green; }
            { value = 1; text = "rate-limited"; color = colors.amber; }
            { value = 2; text = "timed out"; color = colors.amber; }
            { value = 3; text = "attention required"; color = colors.red; }
            { value = 4; text = "reauth required"; color = colors.red; }
            { value = 5; text = "account missing"; color = colors.red; }
            { value = 6; text = "failed"; color = colors.red; }
            { value = 7; text = "not bank-linked"; color = colors.gray; }
            { value = 8; text = "unrecognised status"; color = colors.blue; }
          ]);
          overrides = [ ];
        };
        options = stateTimelineOptions;
      }
      {
        id = 4;
        type = "table";
        title = "Feed age against each account's own lines";
        description = "Latest recorded feed age per account, beside the stale and dead thresholds THAT account was judged by. The lines are per-cadence and deliberately shown per row: a daily feed is stale at 26h and dead at 72h, a monthly statement export at 280h and 840h. One global line across these accounts would call a correctly-behaving mortgage feed dead every morning. Manual accounts have no feed and carry no thresholds; an account with no last_sync falls back to transaction age, which its basis column names.";
        datasource = datasource;
        gridPos = gridPos 8 12 12 11;
        pluginVersion = "12.3.6";
        targets = [
          (query {
            format = "table";
            sql = ''
              SELECT
                account AS "Account",
                cadence AS "Cadence",
                feed_age_hours AS "Feed age",
                feed_stale_threshold_hours AS "Stale at",
                feed_dead_threshold_hours AS "Dead at",
                status AS "Status",
                basis AS "Basis"
              FROM household_finance.sync_health_daily
              WHERE date = (
                SELECT max(date)
                FROM household_finance.sync_health_daily
                WHERE $__timeFilter(date::timestamp)
              )
              ORDER BY feed_age_hours DESC NULLS LAST, account
            '';
          })
        ];
        fieldConfig = {
          defaults = tableFieldDefaults;
          overrides = [
            (fieldOverride "Feed age" [{ id = "unit"; value = "h"; }])
            (fieldOverride "Stale at" [{ id = "unit"; value = "h"; }])
            (fieldOverride "Dead at" [{ id = "unit"; value = "h"; }])
          ];
        };
        options = tableOptions;
      }
      {
        id = 5;
        type = "timeseries";
        title = "Uncategorized backlog — transactions";
        description = "How many register transactions carry no category, register-wide rather than for one month: a charge from March is still someone's work. Off-budget accounts, transfer legs and opening balances are excluded — each is uncategorised by design, and counting them would leave this permanently four figures deep, which is the same as having no queue. That makes this number smaller than finances_transactions(uncategorized_only=true) reports; the gap is scope, not disagreement. Recorded nightly and not backfillable: the register does not record WHEN a transaction was categorised, so history here can only be observed, never reconstructed.";
        datasource = datasource;
        gridPos = gridPos 8 12 0 19;
        pluginVersion = "12.3.6";
        targets = [
          (query {
            sql = ''
              SELECT
                date::timestamp AT TIME ZONE 'America/New_York' AS time,
                uncategorized_count::double precision AS "Uncategorized transactions"
              FROM household_finance.hygiene_daily
              WHERE $__timeFilter(date::timestamp)
              ORDER BY date
            '';
          })
        ];
        fieldConfig = {
          defaults = timeSeriesDefaults {
            fillOpacity = 20;
            unit = "none";
          };
          overrides = [
            (fieldOverride "Uncategorized transactions" [{
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
        title = "Uncategorized backlog — dollars";
        description = "The same queue by magnitude. Deliberately a SEPARATE panel from the count and never a second axis: they share no unit, and a dual axis invites reading a crossing as meaning something. Absolute dollars, summed without regard to direction — an unclassified wire in and an unclassified payment out are two open questions, and netting them would report a tidy zero over both.";
        datasource = datasource;
        gridPos = gridPos 8 12 12 19;
        pluginVersion = "12.3.6";
        targets = [
          (query {
            sql = ''
              SELECT
                date::timestamp AT TIME ZONE 'America/New_York' AS time,
                uncategorized_amount::double precision AS "Uncategorized dollars"
              FROM household_finance.hygiene_daily
              WHERE $__timeFilter(date::timestamp)
              ORDER BY date
            '';
          })
        ];
        fieldConfig = {
          defaults = timeSeriesDefaults { fillOpacity = 20; };
          overrides = [
            (fieldOverride "Uncategorized dollars" [{
              id = "color";
              value = { fixedColor = colors.amber; mode = "fixed"; };
            }])
          ];
        };
        options = timeSeriesOptions;
      }
      {
        id = 7;
        type = "state-timeline";
        title = "Recurring obligations by month";
        description = "One band per configured obligation. MATCHED posted inside its tolerance band; CHANGED posted outside it; MISSING should have posted and did not — the only one worth raising. NOT_DUE and PENDING_STATEMENT are both absences that prove nothing yet. A cell can read CHANGED because the PLAN changed rather than the payment: Starlink shows −98% against a $70 expectation because the household moved it to standby between trips (DECISIONS 2026-08-17), which is working as intended. Every month is judged against the obligation list as it stands TODAY — a recurring item declares an end month but never a start — so older months are a statement about the current plan, not a reconstruction of what the checklist said then. The table holds a rolling twelve months; widen the range to see all of it.";
        datasource = datasource;
        gridPos = gridPos 9 24 0 27;
        pluginVersion = "12.3.6";
        targets = [
          (query {
            sql = ''
              SELECT
                month::timestamp AT TIME ZONE 'America/New_York' AS time,
                (CASE status
                  WHEN 'MATCHED' THEN 0
                  WHEN 'NOT_DUE' THEN 1
                  WHEN 'PENDING_STATEMENT' THEN 2
                  WHEN 'ENDED' THEN 3
                  WHEN 'CHANGED' THEN 4
                  WHEN 'MISSING' THEN 5
                  ELSE 6
                END)::double precision AS value,
                obligation AS metric
              FROM household_finance.recurring_monthly
              WHERE $__timeFilter(month::timestamp)
              ORDER BY month, obligation
            '';
          })
        ];
        fieldConfig = {
          defaults = stateTimelineDefaults (stateMapping [
            { value = 0; text = "matched"; color = colors.green; }
            { value = 1; text = "not due"; color = colors.gray; }
            { value = 2; text = "pending statement"; color = colors.blue; }
            { value = 3; text = "ended"; color = colors.gray; }
            { value = 4; text = "changed"; color = colors.amber; }
            { value = 5; text = "missing"; color = colors.red; }
            { value = 6; text = "unrecognised status"; color = colors.blue; }
          ]);
          overrides = [ ];
        };
        options = stateTimelineOptions;
      }
      {
        id = 8;
        type = "table";
        title = "Export runs";
        description = "Whether the nightly job that fills every other panel in this suite actually ran. A finance dashboard that quietly stops updating looks exactly like a household that stopped spending, which is why this is glass rather than an alert. `Degraded` counts sources the run could not read in full — it still wrote its other tables, and named what it lost. Note this covers the EXPORT only; the sentinel keeps no run history the exporter can reach, so nothing here speaks for it.";
        datasource = datasource;
        gridPos = gridPos 7 12 0 36;
        pluginVersion = "12.3.6";
        targets = [
          (query {
            format = "table";
            sql = ''
              SELECT
                to_char(started_at AT TIME ZONE 'America/New_York', 'YYYY-MM-DD HH24:MI') AS "Started",
                CASE WHEN ok THEN 'ok' ELSE 'FAILED' END AS "Outcome",
                round(extract(epoch FROM (finished_at - started_at))::numeric, 1) AS "Seconds",
                coalesce(array_length(degraded, 1), 0) AS "Degraded",
                error AS "Error"
              FROM household_finance.export_runs
              WHERE $__timeFilter(started_at)
              ORDER BY started_at DESC
              LIMIT 30
            '';
          })
        ];
        fieldConfig = {
          defaults = tableFieldDefaults;
          overrides = [
            (fieldOverride "Seconds" [{ id = "unit"; value = "s"; }])
          ];
        };
        options = tableOptions;
      }
      {
        id = 9;
        type = "timeseries";
        title = "Export duration";
        description = "How long each nightly run took, wall clock. The run recomputes the whole register every night rather than appending a day, so this grows with the register and a sudden step is worth a look — a source that started timing out, or a window that stopped being bounded. Descriptive only.";
        datasource = datasource;
        gridPos = gridPos 7 12 12 36;
        pluginVersion = "12.3.6";
        targets = [
          (query {
            sql = ''
              SELECT
                started_at AS time,
                extract(epoch FROM (finished_at - started_at))::double precision AS "Duration"
              FROM household_finance.export_runs
              WHERE $__timeFilter(started_at)
              ORDER BY started_at
            '';
          })
        ];
        fieldConfig = {
          defaults = timeSeriesDefaults {
            fillOpacity = 12;
            unit = "s";
          };
          overrides = [
            (fieldOverride "Duration" [{
              id = "color";
              value = { fixedColor = colors.blue; mode = "fixed"; };
            }])
          ];
        };
        options = timeSeriesOptions;
      }
    ];
  };

  overviewJson = pkgs.writeText "household-finance-overview.json" (builtins.toJSON overview);
  cashflowJson = pkgs.writeText "household-finance-cashflow.json" (builtins.toJSON cashflow);
  debtJson = pkgs.writeText "household-finance-debt.json" (builtins.toJSON debt);
  dataHealthJson = pkgs.writeText "household-finance-health.json" (builtins.toJSON dataHealth);
in
pkgs.runCommand "household-finance-grafana-dashboards"
{
  passthru.dashboardDefinitions = {
    inherit overview cashflow debt dataHealth;
  };
} ''
  mkdir -p "$out"
  cp ${overviewJson} "$out/overview.json"
  cp ${cashflowJson} "$out/cashflow-categories.json"
  cp ${debtJson} "$out/debt-projects.json"
  cp ${dataHealthJson} "$out/data-health.json"
''
