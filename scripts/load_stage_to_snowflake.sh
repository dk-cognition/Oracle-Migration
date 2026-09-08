#!/usr/bin/env bash
# ============================================================================
# load_stage_to_snowflake.sh
#
# One-time cut-over load: bulk-loads the final Oracle table extracts that were
# uploaded to the inbound stage (s3://hartford-claims-feeds/inbound/<table>.psv)
# into Snowflake with COPY INTO. Continuous inbound payments are handled by
# Snowpipe (db/snowflake/05_stage_pipe.sql); the nightly outbound feed by
# NightlyExtract.java. There is no SQL*Plus spool / SFTP hop any more.
#
# Usage: SNOWFLAKE_APP_PASSWORD=*** ./load_stage_to_snowflake.sh
# ============================================================================
set -euo pipefail

SF_ACCOUNT="${SF_ACCOUNT:-hartford.us-east-1}"
SF_USER="${SF_USER:-HARTFORD_APP}"
SF_ROLE="${SF_ROLE:-CLAIMS_APP_RW}"
SF_WAREHOUSE="${SF_WAREHOUSE:-CLAIMS_WH}"
SF_DATABASE="${SF_DATABASE:-HARTFORD}"
SF_SCHEMA="${SF_SCHEMA:-CLAIMS}"
: "${SNOWFLAKE_APP_PASSWORD:?Set SNOWFLAKE_APP_PASSWORD}"
export SNOWSQL_PWD="${SNOWFLAKE_APP_PASSWORD}"

TABLES=(agent customer policy claim claim_payment)

for t in "${TABLES[@]}"; do
  echo "Loading @claims_stage/${t}.psv -> ${SF_DATABASE}.${SF_SCHEMA}.${t} ..."
  snowsql -a "${SF_ACCOUNT}" -u "${SF_USER}" -r "${SF_ROLE}" \
          -w "${SF_WAREHOUSE}" -d "${SF_DATABASE}" -s "${SF_SCHEMA}" \
          -o quiet=true -o friendly=false -q "
    COPY INTO ${t}
      FROM @claims_stage/${t}.psv
      FILE_FORMAT = (FORMAT_NAME = ff_psv)
      ON_ERROR = 'ABORT_STATEMENT';"
done

echo "Done. Recreate the sequences above MAX(id) per db/snowflake/05_stage_pipe.sql."
