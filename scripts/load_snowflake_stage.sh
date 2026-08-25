#!/usr/bin/env bash
# ============================================================================
# load_snowflake_stage.sh
#
# Bulk/backfill load path for the Snowflake target: PUTs local pipe-delimited
# files onto @claims_stage, where Snowpipe (pipe_claims_load) picks them up
# automatically. Day-to-day inbound loading needs no script at all - files
# landed on the stage's cloud bucket are ingested continuously by Snowpipe.
#
# Replaces the legacy export_oracle_to_stage.sh (SQL*Plus spool -> SFTP hop).
#
# Usage: SNOWFLAKE_APP_PASSWORD=*** ./load_snowflake_stage.sh /path/to/indir
# Requires: snowsql CLI (https://docs.snowflake.com/en/user-guide/snowsql)
# ============================================================================
set -euo pipefail

IN_DIR="${1:-./extract}"
SF_ACCOUNT="${SF_ACCOUNT:-hartford.us-east-1}"
SF_USER="${SF_USER:-HARTFORD_APP}"
SF_WAREHOUSE="${SF_WAREHOUSE:-CLAIMS_WH}"
SF_DATABASE="${SF_DATABASE:-HARTFORD}"
SF_SCHEMA="${SF_SCHEMA:-CLAIMS}"
SF_ROLE="${SF_ROLE:-CLAIMS_APP_RW}"
: "${SNOWFLAKE_APP_PASSWORD:?Set SNOWFLAKE_APP_PASSWORD}"

TABLES=(customer agent policy claim claim_payment)

for t in "${TABLES[@]}"; do
  f="${IN_DIR}/${t}.psv"
  if [[ ! -f "${f}" ]]; then
    echo "Skipping ${t}: ${f} not found"
    continue
  fi
  echo "Staging ${f} -> @claims_stage/${t}/ ..."
  SNOWSQL_PWD="${SNOWFLAKE_APP_PASSWORD}" snowsql \
    -a "${SF_ACCOUNT}" -u "${SF_USER}" -r "${SF_ROLE}" \
    -w "${SF_WAREHOUSE}" -d "${SF_DATABASE}" -s "${SF_SCHEMA}" \
    -q "PUT file://${f} @claims_stage/${t}/ AUTO_COMPRESS=TRUE"
done

echo "Done. Snowpipe (pipe_claims_load) ingests staged claim files automatically;"
echo "for other tables run: COPY INTO ${SF_SCHEMA}.<table> FROM @claims_stage/<table>/ FILE_FORMAT=(FORMAT_NAME=ff_claims_psv)"
