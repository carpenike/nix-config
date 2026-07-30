#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: tracearr-retention-plan [--batch-size N]

Generate a read-only JSON plan for catching up Tracearr's TimescaleDB
retention policy. N must be between 1 and 8 (default: 8).
EOF
}

batch_size=8

while (($# > 0)); do
    case "$1" in
        --batch-size)
            if (($# < 2)); then
                echo "--batch-size requires a value" >&2
                exit 2
            fi
            batch_size="$2"
            shift 2
            ;;
        --help | -h)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [[ ! "$batch_size" =~ ^[1-8]$ ]]; then
    echo "Batch size must be an integer from 1 through 8" >&2
    exit 2
fi

export PGOPTIONS="${PGOPTIONS:+$PGOPTIONS }-c default_transaction_read_only=on -c statement_timeout=120s -c lock_timeout=5s"

if ! plan_json="$(
    psql \
        --dbname=tracearr \
        --no-psqlrc \
        --quiet \
        --tuples-only \
        --no-align \
        --set=ON_ERROR_STOP=1 \
        --set="batch_size=$batch_size" <<'SQL'
WITH policy_matches AS MATERIALIZED (
    SELECT
        jobs.job_id,
        jobs.application_name,
        jobs.schedule_interval,
        jobs.scheduled,
        jobs.config,
        stats.last_run_status,
        stats.last_run_started_at,
        stats.last_successful_finish,
        stats.total_runs,
        stats.total_successes,
        stats.total_failures,
        stats.next_start
    FROM timescaledb_information.jobs AS jobs
    LEFT JOIN timescaledb_information.job_stats AS stats USING (job_id)
    WHERE jobs.proc_name = 'policy_retention'
      AND jobs.hypertable_schema = 'public'
      AND jobs.hypertable_name = 'library_snapshots'
),
policy_validation AS (
    SELECT
        count(*) AS match_count,
        count(*) FILTER (WHERE config ? 'drop_after') AS configured_count
    FROM policy_matches
),
policy AS MATERIALIZED (
    SELECT
        matches.*,
        (matches.config ->> 'drop_after')::interval AS drop_after
    FROM policy_matches AS matches
    CROSS JOIN policy_validation AS validation
    WHERE validation.match_count = 1
      AND validation.configured_count = 1
),
plan_context AS MATERIALIZED (
    SELECT
        statement_timestamp() AS generated_at,
        statement_timestamp() - policy.drop_after AS retention_cutoff,
        :'batch_size'::integer AS batch_size,
        policy.*
    FROM policy
),
selected_chunks AS MATERIALIZED (
    SELECT selected.chunk::oid AS chunk_oid
    FROM plan_context AS context
    CROSS JOIN LATERAL show_chunks(
        'public.library_snapshots'::regclass,
        older_than => context.retention_cutoff
    ) AS selected(chunk)
),
chunk_details AS MATERIALIZED (
    SELECT
        selected.chunk_oid,
        chunks.chunk_schema::text AS chunk_schema,
        chunks.chunk_name::text AS chunk_name,
        chunks.range_start,
        chunks.range_end,
        chunks.is_compressed,
        coalesce(sizes.table_bytes, 0) AS table_bytes,
        coalesce(sizes.index_bytes, 0) AS index_bytes,
        coalesce(sizes.toast_bytes, 0) AS toast_bytes,
        coalesce(sizes.total_bytes, 0) AS total_bytes
    FROM selected_chunks AS selected
    JOIN pg_class AS relations
      ON relations.oid = selected.chunk_oid
    JOIN pg_namespace AS namespaces
      ON namespaces.oid = relations.relnamespace
    JOIN timescaledb_information.chunks AS chunks
      ON chunks.chunk_schema = namespaces.nspname
     AND chunks.chunk_name = relations.relname
    LEFT JOIN chunks_detailed_size(
        'public.library_snapshots'::regclass
    ) AS sizes
      ON sizes.chunk_schema = chunks.chunk_schema
     AND sizes.chunk_name = chunks.chunk_name
    WHERE chunks.hypertable_schema = 'public'
      AND chunks.hypertable_name = 'library_snapshots'
),
ranked_chunks AS MATERIALIZED (
    SELECT
        details.*,
        row_number() OVER (
            ORDER BY range_end, chunk_schema, chunk_name
        ) AS ordinal,
        1 + (
            (row_number() OVER (
                ORDER BY range_end, chunk_schema, chunk_name
            ) - 1) / context.batch_size
        ) AS batch_id
    FROM chunk_details AS details
    CROSS JOIN plan_context AS context
),
batch_rows AS MATERIALIZED (
    SELECT
        batch_id,
        count(*) AS chunk_count,
        max(ordinal) AS cumulative_ordinal_through_batch,
        min(range_start) AS oldest_range_start,
        max(range_end) AS proposed_older_than,
        sum(total_bytes) AS total_bytes,
        jsonb_agg(
            jsonb_build_object(
                'ordinal', ordinal,
                'oid', chunk_oid,
                'qualified_name', format('%I.%I', chunk_schema, chunk_name),
                'range_start', range_start,
                'range_end', range_end,
                'compressed', is_compressed,
                'table_bytes', table_bytes,
                'index_bytes', index_bytes,
                'toast_bytes', toast_bytes,
                'total_bytes', total_bytes
            )
            ORDER BY ordinal
        ) AS chunks
    FROM ranked_chunks
    GROUP BY batch_id
),
plan_totals AS (
    SELECT
        count(*) AS expired_chunk_count,
        coalesce(sum(total_bytes), 0) AS expired_total_bytes,
        count(*) FILTER (WHERE is_compressed) AS compressed_chunk_count,
        md5(coalesce(string_agg(
            concat_ws(
                ':',
                chunk_oid,
                chunk_schema,
                chunk_name,
                range_start,
                range_end
            ),
            ',' ORDER BY ordinal
        ), '')) AS selection_fingerprint
    FROM ranked_chunks
),
dependencies AS (
    SELECT coalesce(
        jsonb_agg(
            format('%I.%I', view_schema, view_name)
            ORDER BY view_schema, view_name
        ),
        '[]'::jsonb
    ) AS names
    FROM timescaledb_information.continuous_aggregates
    WHERE hypertable_schema = 'public'
      AND hypertable_name = 'library_snapshots'
),
latest_error AS (
    SELECT jsonb_build_object(
        'sqlstate', errors.sqlerrcode,
        'message', errors.err_message,
        'started_at', errors.start_time,
        'finished_at', errors.finish_time
    ) AS value
    FROM timescaledb_information.job_errors AS errors
    JOIN plan_context AS context USING (job_id)
    ORDER BY errors.finish_time DESC
    LIMIT 1
),
ready_plan AS (
    SELECT jsonb_build_object(
        'schema_version', 1,
        'status', 'ready',
        'read_only', true,
        'database', current_database(),
        'timescaledb_version', (
            SELECT extversion
            FROM pg_extension
            WHERE extname = 'timescaledb'
        ),
        'hypertable', 'public.library_snapshots',
        'generated_at', context.generated_at,
        'retention_interval', context.drop_after,
        'retention_cutoff', context.retention_cutoff,
        'batch_size', context.batch_size,
        'max_locks_per_transaction',
            current_setting('max_locks_per_transaction')::integer,
        'expired_chunk_count', totals.expired_chunk_count,
        'expired_total_bytes', totals.expired_total_bytes,
        'compressed_chunk_count', totals.compressed_chunk_count,
        'batch_count', (
            SELECT count(*)
            FROM batch_rows
        ),
        'selection_fingerprint', totals.selection_fingerprint,
        'retention_job', jsonb_build_object(
            'job_id', context.job_id,
            'application_name', context.application_name,
            'scheduled', context.scheduled,
            'schedule_interval', context.schedule_interval,
            'last_run_status', context.last_run_status,
            'last_run_started_at', context.last_run_started_at,
            'last_successful_finish', context.last_successful_finish,
            'total_runs', context.total_runs,
            'total_successes', context.total_successes,
            'total_failures', context.total_failures,
            'next_start', context.next_start,
            'config', context.config,
            'latest_error', (
                SELECT value
                FROM latest_error
            )
        ),
        'continuous_aggregates', dependencies.names,
        'execution_invariants', jsonb_build_array(
            'Revalidate the exact chunk OIDs, names, and ranges before each batch.',
            'Execute batches sequentially from the lowest batch_id.',
            'Use one transaction per batch and stop after any mismatch or error.',
            'Do not alter the retention policy or global lock budget during catch-up.'
        ),
        'batches', coalesce((
            SELECT jsonb_agg(
                jsonb_build_object(
                    'batch_id', batch_id,
                    'chunk_count', chunk_count,
                    'cumulative_ordinal_through_batch',
                        cumulative_ordinal_through_batch,
                    'oldest_range_start', oldest_range_start,
                    'proposed_older_than', proposed_older_than,
                    'total_bytes', total_bytes,
                    'chunks', chunks
                )
                ORDER BY batch_id
            )
            FROM batch_rows
        ), '[]'::jsonb)
    ) AS document
    FROM plan_context AS context
    CROSS JOIN plan_totals AS totals
    CROSS JOIN dependencies
),
error_plan AS (
    SELECT jsonb_build_object(
        'schema_version', 1,
        'status', 'error',
        'read_only', true,
        'database', current_database(),
        'hypertable', 'public.library_snapshots',
        'message', CASE
            WHEN match_count = 0 THEN
                'No retention policy exists for the target hypertable.'
            WHEN match_count > 1 THEN
                'Multiple retention policies exist for the target hypertable.'
            ELSE
                'The retention policy does not define drop_after.'
        END,
        'matching_policy_count', match_count,
        'configured_policy_count', configured_count
    ) AS document
    FROM policy_validation
)
SELECT coalesce(
    (SELECT document FROM ready_plan),
    (SELECT document FROM error_plan)
)::text;
SQL
)"; then
    echo "Failed to generate Tracearr retention plan" >&2
    exit 1
fi

if ! jq -e '.status == "ready" and .read_only == true' <<<"$plan_json" >/dev/null; then
    jq . <<<"$plan_json" >&2 || printf '%s\n' "$plan_json" >&2
    exit 1
fi

jq . <<<"$plan_json"
