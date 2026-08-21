#!/usr/bin/env bash
# ============================================================================
# load_stage_to_snowflake.sh
#
# Replaces the legacy SQL*Plus spool + SFTP extract (export_oracle_to_stage.sh).
# Files land in cloud storage behind the @claims_stage external stage; this
# script drives the COPY INTO for each table and refreshes the Snowpipes that
# handle continuous load. No flat-file hop, no local extract directory.
#
# Usage:
#   SNOWFLAKE_APP_PASSWORD=*** ./load_stage_to_snowflake.sh [stage_prefix]
#
# Environment:
#   SNOWSQL_ACCOUNT   Snowflake account identifier (default hartford.us-east-1)
#   SNOWSQL_USER      user (default HARTFORD_APP)
#   SNOWSQL_ROLE      role (default CLAIMS_APP_RW)
#   SNOWSQL_WAREHOUSE warehouse (default CLAIMS_WH)
# ============================================================================
set -euo pipefail

STAGE_PREFIX="${1:-}"
SNOWSQL_ACCOUNT="${SNOWSQL_ACCOUNT:-hartford.us-east-1}"
SNOWSQL_USER="${SNOWSQL_USER:-HARTFORD_APP}"
SNOWSQL_ROLE="${SNOWSQL_ROLE:-CLAIMS_APP_RW}"
SNOWSQL_WAREHOUSE="${SNOWSQL_WAREHOUSE:-CLAIMS_WH}"
: "${SNOWFLAKE_APP_PASSWORD:?Set SNOWFLAKE_APP_PASSWORD}"

TABLES=(customer agent policy claim claim_payment)

run_sql() {
  SNOWSQL_PWD="${SNOWFLAKE_APP_PASSWORD}" snowsql \
    -a "${SNOWSQL_ACCOUNT}" \
    -u "${SNOWSQL_USER}" \
    -r "${SNOWSQL_ROLE}" \
    -w "${SNOWSQL_WAREHOUSE}" \
    -d HARTFORD -s CLAIMS \
    -o friendly=false -o quiet=true -o exit_on_error=true \
    -q "$1"
}

for t in "${TABLES[@]}"; do
  echo "Loading hartford.claims.${t} from @claims_stage/${STAGE_PREFIX}${t}/ ..."
  run_sql "COPY INTO hartford.claims.${t}
             FROM @hartford.claims.claims_stage/${STAGE_PREFIX}${t}/
             FILE_FORMAT = (FORMAT_NAME = hartford.claims.ff_claims_psv)
             ON_ERROR = ABORT_STATEMENT;"
done

# Pick up any files that arrived before the pipes were created / while paused.
for p in pipe_claim pipe_claim_payment; do
  echo "Refreshing ${p} ..."
  run_sql "ALTER PIPE hartford.claims.${p} REFRESH;"
done

echo "Done. Load history: SELECT * FROM TABLE(INFORMATION_SCHEMA.COPY_HISTORY(...));"
