#!/usr/bin/env bash
# ============================================================================
# unload_to_snowflake_stage.sh
#
# Replaces the legacy export_oracle_to_stage.sh (SQL*Plus spool -> flat file ->
# SFTP). Each table is unloaded with COPY INTO directly to the cloud stage; the
# warehouse side picks the files up with Snowpipe (db/snowflake/05_stages_snowpipe.sql).
#
# Usage: SNOWFLAKE_APP_PASSWORD=*** ./unload_to_snowflake_stage.sh [stage_prefix]
# ============================================================================
set -euo pipefail

STAGE_PREFIX="${1:-@hartford.claims.claims_stage/nightly}"
SF_ACCOUNT="${SF_ACCOUNT:-hartford.us-east-1}"
SF_USER="${SF_USER:-HARTFORD_APP}"
SF_ROLE="${SF_ROLE:-CLAIMS_APP_RW}"
SF_WAREHOUSE="${SF_WAREHOUSE:-CLAIMS_WH}"
SF_DATABASE="${SF_DATABASE:-HARTFORD}"
SF_SCHEMA="${SF_SCHEMA:-CLAIMS}"
: "${SNOWFLAKE_APP_PASSWORD:?Set SNOWFLAKE_APP_PASSWORD}"

TABLES=(customer agent policy claim claim_payment)

export SNOWSQL_PWD="${SNOWFLAKE_APP_PASSWORD}"

for t in "${TABLES[@]}"; do
  echo "Unloading ${SF_DATABASE}.${SF_SCHEMA}.${t} to ${STAGE_PREFIX}/${t}/ ..."
  snowsql -a "${SF_ACCOUNT}" -u "${SF_USER}" -r "${SF_ROLE}" \
          -w "${SF_WAREHOUSE}" -d "${SF_DATABASE}" -s "${SF_SCHEMA}" \
          -o friendly=false -o exit_on_error=true \
          -q "COPY INTO ${STAGE_PREFIX}/${t}/${t}_
                FROM ${SF_DATABASE}.${SF_SCHEMA}.${t}
                FILE_FORMAT = (TYPE = CSV COMPRESSION = GZIP FIELD_DELIMITER = '|')
                HEADER = TRUE
                OVERWRITE = TRUE
                MAX_FILE_SIZE = 100000000;"
done

echo "Done. Files staged under ${STAGE_PREFIX}; Snowpipe loads them downstream."
