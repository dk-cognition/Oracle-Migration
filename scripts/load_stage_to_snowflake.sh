#!/usr/bin/env bash
# ============================================================================
# load_stage_to_snowflake.sh
#
# Replaces the legacy export_oracle_to_stage.sh flat-file extract. Bulk-loads
# pipe-delimited feed files into Snowflake: PUT them onto the internal stage,
# then COPY INTO the target tables. Continuous loading of the claim feed is
# handled by Snowpipe (db/snowflake/05_stage_and_pipe.sql).
#
# Usage: SNOWFLAKE_APP_PASSWORD=*** ./load_stage_to_snowflake.sh /path/to/feed_dir
# Requires: snowsql CLI configured with a connection named "hartford".
# ============================================================================
set -euo pipefail

FEED_DIR="${1:-./feed}"
SNOWSQL_CONN="${SNOWSQL_CONN:-hartford}"
: "${SNOWFLAKE_APP_PASSWORD:?Set SNOWFLAKE_APP_PASSWORD}"

TABLES=(customer agent policy claim claim_payment)

for t in "${TABLES[@]}"; do
  f="${FEED_DIR}/${t}.psv"
  if [[ ! -f "${f}" ]]; then
    echo "Skipping ${t}: no ${f}"
    continue
  fi
  echo "Loading ${f} -> hartford.${t} ..."
  SNOWSQL_PWD="${SNOWFLAKE_APP_PASSWORD}" snowsql -c "${SNOWSQL_CONN}" -o exit_on_error=true <<SQL
    USE SCHEMA hartford;
    PUT file://${f} @hartford.claims_stage/${t}/ AUTO_COMPRESS=TRUE;
    COPY INTO hartford.${t}
      FROM @hartford.claims_stage/${t}/
      FILE_FORMAT = (FORMAT_NAME = 'hartford.ff_psv')
      ON_ERROR = 'ABORT_STATEMENT';
SQL
done

echo "Done. Data loaded into Snowflake from ${FEED_DIR}"
