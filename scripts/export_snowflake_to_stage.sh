#!/usr/bin/env bash
# ============================================================================
# export_snowflake_to_stage.sh
#
# Nightly unload: writes each claims table to the cloud stage with COPY INTO,
# replacing the legacy SQL*Plus spool + SFTP flat-file hop. Downstream loads
# read straight from the stage, or Snowpipe (see below) ingests continuously.
#
# Usage: SNOWFLAKE_APP_PASSWORD=*** ./export_snowflake_to_stage.sh [stage_path]
# ============================================================================
set -euo pipefail

STAGE="${1:-@claims_stage}"
SF_ACCOUNT="${SF_ACCOUNT:-hartford.us-east-1}"
SF_USER="${SF_USER:-HARTFORD_APP}"
SF_ROLE="${SF_ROLE:-CLAIMS_APP_RW}"
SF_WAREHOUSE="${SF_WAREHOUSE:-CLAIMS_WH}"
SF_DATABASE="${SF_DATABASE:-HARTFORD}"
SF_SCHEMA="${SF_SCHEMA:-CLAIMS}"
: "${SNOWFLAKE_APP_PASSWORD:?Set SNOWFLAKE_APP_PASSWORD}"

export SNOWSQL_PWD="${SNOWFLAKE_APP_PASSWORD}"

TABLES=(customer agent policy claim claim_payment)

for t in "${TABLES[@]}"; do
  echo "Unloading ${SF_DATABASE}.${SF_SCHEMA}.${t} to ${STAGE}/${t}/ ..."
  snowsql -a "${SF_ACCOUNT}" -u "${SF_USER}" -r "${SF_ROLE}" \
          -w "${SF_WAREHOUSE}" -d "${SF_DATABASE}" -s "${SF_SCHEMA}" \
          -o friendly=false -o quiet=true -q "
    COPY INTO ${STAGE}/${t}/
    FROM ${SF_DATABASE}.${SF_SCHEMA}.${t}
    FILE_FORMAT = (TYPE = CSV FIELD_DELIMITER = '|' COMPRESSION = GZIP)
    HEADER = TRUE
    OVERWRITE = TRUE;"
done

# Incremental claim feed driven by the stream created in
# db/snowflake/04_streams_tasks.sql (replaces TRUNC(SYSDATE) - 1 windowing).
echo "Unloading claim CDC rows from strm_claim_changes ..."
snowsql -a "${SF_ACCOUNT}" -u "${SF_USER}" -r "${SF_ROLE}" \
        -w "${SF_WAREHOUSE}" -d "${SF_DATABASE}" -s "${SF_SCHEMA}" \
        -o friendly=false -o quiet=true -q "
  COPY INTO ${STAGE}/claim_cdc/
  FROM (
    SELECT s.claim_id, s.claim_number, s.policy_id,
           TO_VARCHAR(s.reported_date, 'YYYY-MM-DD HH24:MI:SS') AS reported,
           s.status, s.reserve_amount, s.paid_amount,
           s.METADATA\$ACTION AS cdc_action
      FROM strm_claim_changes s
  )
  FILE_FORMAT = (TYPE = CSV FIELD_DELIMITER = '|' COMPRESSION = GZIP)
  HEADER = TRUE;"

echo "Done. Files staged under ${STAGE}."
echo "Continuous ingestion alternative (create once, then no scheduling needed):"
echo "  CREATE PIPE claims_pipe AUTO_INGEST = TRUE AS"
echo "    COPY INTO ${SF_DATABASE}.${SF_SCHEMA}.claim FROM ${STAGE}/claim/"
echo "    FILE_FORMAT = (TYPE = CSV FIELD_DELIMITER = '|' SKIP_HEADER = 1);"
