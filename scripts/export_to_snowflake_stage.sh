#!/usr/bin/env bash
# ============================================================================
# export_to_snowflake_stage.sh
#
# Snowflake replacement for the legacy SQL*Plus spool -> SFTP flat-file export.
# Instead of dumping tables to pipe-delimited files and SFTP'ing them to the
# warehouse, this unloads each table straight into a Snowflake stage with
# COPY INTO (no flat-file hop). For continuous load, attach a Snowpipe to the
# stage instead of running this batch. See docs/MIGRATION.md.
#
# Requires SnowSQL configured with a connection (see ~/.snowsql/config), or pass
# the connection via env vars below. The account password comes from
# SNOWFLAKE_APP_PASSWORD.
#
# Usage: SNOWFLAKE_APP_PASSWORD=*** ./export_to_snowflake_stage.sh [stage_name]
# ============================================================================
set -euo pipefail

STAGE="${1:-@CLAIMS_STAGE}"
SF_ACCOUNT="${SF_ACCOUNT:-hartford.us-east-1}"
SF_USER="${SF_USER:-HARTFORD_APP}"
SF_ROLE="${SF_ROLE:-CLAIMS_APP_RW}"
SF_WAREHOUSE="${SF_WAREHOUSE:-CLAIMS_WH}"
SF_DATABASE="${SF_DATABASE:-HARTFORD}"
SF_SCHEMA="${SF_SCHEMA:-CLAIMS}"
: "${SNOWFLAKE_APP_PASSWORD:?Set SNOWFLAKE_APP_PASSWORD}"

TABLES=(customer agent policy claim claim_payment)

for t in "${TABLES[@]}"; do
  echo "Unloading ${SF_DATABASE}.${SF_SCHEMA}.${t} -> ${STAGE}/${t}/ ..."
  SNOWSQL_PWD="${SNOWFLAKE_APP_PASSWORD}" snowsql \
    -a "${SF_ACCOUNT}" -u "${SF_USER}" -r "${SF_ROLE}" \
    -w "${SF_WAREHOUSE}" -d "${SF_DATABASE}" -s "${SF_SCHEMA}" \
    -q "COPY INTO ${STAGE}/${t}/
          FROM ${t}
          FILE_FORMAT = (TYPE = CSV FIELD_DELIMITER = '|' COMPRESSION = GZIP)
          HEADER = TRUE
          OVERWRITE = TRUE;"
done

echo "Done. Data unloaded to Snowflake stage ${STAGE}."
echo "Downstream consumers read from the stage (or via Snowpipe) -- no SFTP."
