#!/usr/bin/env bash
# ============================================================================
# export_to_snowflake_stage.sh
#
# Nightly publish of the claims tables to the warehouse feed, migrated from the
# Oracle SQL*Plus spool + SFTP flat-file hop (export_oracle_to_stage.sh).
#
# Everything now runs inside Snowflake via SnowSQL:
#   * COPY INTO @claims_stage/<table>/  unloads each table as Parquet.
#   * A Snowpipe (pipe_claims_ingest) ingests anything a producer drops in the
#     stage, so the downstream warehouse no longer polls for files. It is an
#     internal stage, so the pipe is triggered through the Snowpipe REST API;
#     switch the stage to S3/GCS/Azure to enable AUTO_INGEST notifications.
#   * TRUNC(SYSDATE) - 1 becomes DATEADD('day', -1, CURRENT_DATE()).
#
# Usage: SNOWFLAKE_APP_PASSWORD=*** ./export_to_snowflake_stage.sh [stage_path]
# ============================================================================
set -euo pipefail

STAGE_PATH="${1:-@hartford.claims.claims_stage}"
SF_ACCOUNT="${SF_ACCOUNT:-hartford.us-east-1}"
SF_USER="${SF_USER:-HARTFORD_APP}"
SF_ROLE="${SF_ROLE:-CLAIMS_APP_RW}"
SF_WAREHOUSE="${SF_WAREHOUSE:-CLAIMS_WH}"
SF_DATABASE="${SF_DATABASE:-HARTFORD}"
SF_SCHEMA="${SF_SCHEMA:-CLAIMS}"
: "${SNOWFLAKE_APP_PASSWORD:?Set SNOWFLAKE_APP_PASSWORD}"

snowsql_exec() {
  SNOWSQL_PWD="${SNOWFLAKE_APP_PASSWORD}" snowsql \
    --accountname "${SF_ACCOUNT}" \
    --username "${SF_USER}" \
    --rolename "${SF_ROLE}" \
    --warehouse "${SF_WAREHOUSE}" \
    --dbname "${SF_DATABASE}" \
    --schemaname "${SF_SCHEMA}" \
    --option friendly=false \
    --option quiet=true \
    --option exit_on_error=true \
    --query "$1"
}

TABLES=(customer agent policy claim claim_payment)

# One-time-ish setup: internal stage, file format and the Snowpipe that replaces
# the SFTP-and-poll handoff. All are CREATE IF NOT EXISTS, so re-running is safe.
echo "Ensuring stage / file format / pipe exist ..."
snowsql_exec "
  CREATE FILE FORMAT IF NOT EXISTS hartford.claims.ff_claims_parquet
    TYPE = PARQUET COMPRESSION = SNAPPY;
  CREATE STAGE IF NOT EXISTS hartford.claims.claims_stage
    FILE_FORMAT = hartford.claims.ff_claims_parquet;
  CREATE PIPE IF NOT EXISTS hartford.claims.pipe_claims_ingest
  AS
    COPY INTO hartford.claims.claim
      FROM @hartford.claims.claims_stage/claim/
      FILE_FORMAT = (FORMAT_NAME = hartford.claims.ff_claims_parquet)
      MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;
"

for t in "${TABLES[@]}"; do
  echo "Unloading hartford.claims.${t} ..."
  snowsql_exec "
    COPY INTO ${STAGE_PATH}/${t}/
      FROM hartford.claims.${t}
      FILE_FORMAT = (FORMAT_NAME = hartford.claims.ff_claims_parquet)
      OVERWRITE = TRUE;
  "
done

# Incremental slice the nightly warehouse job consumes (was TRUNC(SYSDATE) - 1).
echo "Unloading yesterday's changed claims ..."
snowsql_exec "
  COPY INTO ${STAGE_PATH}/claim_delta/
    FROM (
      SELECT *
        FROM hartford.claims.claim
       WHERE reported_date >= DATEADD('day', -1, CURRENT_DATE())
    )
    FILE_FORMAT = (FORMAT_NAME = hartford.claims.ff_claims_parquet)
    OVERWRITE = TRUE;
"

echo "Done. Files staged under ${STAGE_PATH}; pipe_claims_ingest auto-ingests new arrivals."
