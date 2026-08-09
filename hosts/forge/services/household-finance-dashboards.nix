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
        lineInterpolation = "smooth";
        lineWidth = 2;
        pointSize = 5;
        scaleDistribution.type = "linear";
        showPoints = "never";
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
  ];

  dashboard =
    { title
    , uid
    , panels
    , annotations ? [ ]
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
        from = "now-2y";
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
        description = "Exact lading attribution remains separate from (unattributed); no charge is spread or dropped.";
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
          defaults = {
            custom = {
              align = "auto";
              cellOptions.type = "auto";
              inspect = false;
            };
            mappings = [ ];
          };
          overrides = [
            (fieldOverride "Spend" [{ id = "unit"; value = "currencyUSD"; }])
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
        description = "Newest point may use bank-available basis; historical points use the register. Events annotate breaches, bridges, strikes, and dated notes.";
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
        ];
        fieldConfig = {
          defaults = timeSeriesDefaults { fillOpacity = 12; };
          overrides = [
            (fieldOverride "Buffer" [{ id = "color"; value = { fixedColor = colors.green; mode = "fixed"; }; }])
            (fieldOverride "Checking available" [{ id = "color"; value = { fixedColor = colors.blue; mode = "fixed"; }; }])
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
        gridPos = gridPos 8 24 0 20;
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
          defaults = {
            custom = {
              align = "auto";
              cellOptions.type = "auto";
              inspect = false;
            };
            mappings = [ ];
          };
          overrides = [
            (fieldOverride "Amount" [{ id = "unit"; value = "currencyUSD"; }])
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

  overviewJson = pkgs.writeText "household-finance-overview.json" (builtins.toJSON overview);
  cashflowJson = pkgs.writeText "household-finance-cashflow.json" (builtins.toJSON cashflow);
  debtJson = pkgs.writeText "household-finance-debt.json" (builtins.toJSON debt);
in
pkgs.runCommand "household-finance-grafana-dashboards"
{
  passthru.dashboardDefinitions = {
    inherit overview cashflow debt;
  };
} ''
  mkdir -p "$out"
  cp ${overviewJson} "$out/overview.json"
  cp ${cashflowJson} "$out/cashflow-categories.json"
  cp ${debtJson} "$out/debt-projects.json"
''
