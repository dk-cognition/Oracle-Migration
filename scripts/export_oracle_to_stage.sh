#!/usr/bin/env bash
# ============================================================================
# export_oracle_to_stage.sh  (migrated to Snowflake)
#
# Nightly extract, Snowflake-native. Replaces the legacy SQL*Plus spool -> SFTP
# flow with `COPY INTO @claims_stage/...` unloads run through snowsql. Each table
# is unloaded straight to the named cloud stage; Snowpipe / the warehouse feed
# ingests from there (no flat-file hop). See docs/MIGRATION.md section 8.
#
# Usage:
#   SNOWFLAKE_APP_PASSWORD=*** ./export_oracle_to_stage.sh [stage_prefix]
#
# Environment:
#   SF_ACCOUNT   Snowflake account identifier (default hartford)
#   SF_USER      Snowflake user               (default HARTFORD_APP)
#   SF_ROLE      Role                          (default CLAIMS_APP_RW)
#   SF_WAREHOUSE Warehouse                     (default CLAIMS_WH)
#   SF_DATABASE  Database                      (default HARTFORD)
#   SF_SCHEMA    Schema                        (default HARTFORD)
#   SNOWFLAKE_APP_PASSWORD  (required)
# ============================================================================
set -euo pipefail

STAGE_PREFIX="${1:-@claims_stage}"
SF_ACCOUNT="${SF_ACCOUNT:-hartford}"
SF_USER="${SF_USER:-HARTFORD_APP}"
SF_ROLE="${SF_ROLE:-CLAIMS_APP_RW}"
SF_WAREHOUSE="${SF_WAREHOUSE:-CLAIMS_WH}"
SF_DATABASE="${SF_DATABASE:-HARTFORD}"
SF_SCHEMA="${SF_SCHEMA:-HARTFORD}"
: "${SNOWFLAKE_APP_PASSWORD:?Set SNOWFLAKE_APP_PASSWORD}"

TABLES=(customer agent policy claim claim_payment)

for t in "${TABLES[@]}"; do
  echo "Unloading ${SF_DATABASE}.${SF_SCHEMA}.${t} to ${STAGE_PREFIX}/${t}/ ..."
  SNOWSQL_PWD="${SNOWFLAKE_APP_PASSWORD}" snowsql \
    -a "${SF_ACCOUNT}" -u "${SF_USER}" -r "${SF_ROLE}" \
    -w "${SF_WAREHOUSE}" -d "${SF_DATABASE}" -s "${SF_SCHEMA}" \
    -q "COPY INTO ${STAGE_PREFIX}/${t}/
          FROM ${SF_DATABASE}.${SF_SCHEMA}.${t}
          FILE_FORMAT = (TYPE = CSV FIELD_DELIMITER = '|' NULL_IF = ('') EMPTY_FIELD_AS_NULL = FALSE)
          HEADER = TRUE
          OVERWRITE = TRUE;"
done

echo "Done. Unloaded files are in the Snowflake stage ${STAGE_PREFIX}/<table>/"
echo "Downstream ingestion is handled by Snowpipe / COPY INTO from ${STAGE_PREFIX}."
