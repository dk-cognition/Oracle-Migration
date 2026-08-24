#!/usr/bin/env bash
# ============================================================================
# load_stage_to_snowflake.sh
#
# Uploads pipe-delimited source files to the Snowflake cloud stage and loads
# the five Hartford tables. Snowflake load metadata makes repeated runs safe.
#
# Usage: SNOWFLAKE_APP_PASSWORD=*** ./load_stage_to_snowflake.sh [input_dir]
# ============================================================================
set -euo pipefail

INPUT_DIR="${1:-./stage}"
STAGE_PATH="${SNOWSQL_STAGE_PATH:-@hartford.claims_stage/incoming}"
FILE_FORMAT="${SNOWSQL_FILE_FORMAT:-hartford.claims_pipe_format}"

: "${SNOWSQL_ACCOUNT:?Set SNOWSQL_ACCOUNT}"
: "${SNOWSQL_USER:?Set SNOWSQL_USER}"
: "${SNOWSQL_DATABASE:?Set SNOWSQL_DATABASE}"
: "${SNOWSQL_SCHEMA:?Set SNOWSQL_SCHEMA}"
: "${SNOWSQL_WAREHOUSE:?Set SNOWSQL_WAREHOUSE}"
: "${SNOWSQL_ROLE:?Set SNOWSQL_ROLE}"
: "${SNOWFLAKE_APP_PASSWORD:?Set SNOWFLAKE_APP_PASSWORD}"

export SNOWSQL_PWD="${SNOWFLAKE_APP_PASSWORD}"
SNOWSQL_COMMON=(
  snowsql
  -a "${SNOWSQL_ACCOUNT}"
  -u "${SNOWSQL_USER}"
  -d "${SNOWSQL_DATABASE}"
  -s "${SNOWSQL_SCHEMA}"
  -w "${SNOWSQL_WAREHOUSE}"
  -r "${SNOWSQL_ROLE}"
  -o exit_on_error=true
)

tables=(customer agent policy claim claim_payment)
for table in "${tables[@]}"; do
  echo "Uploading ${table} ..."
  "${SNOWSQL_COMMON[@]}" -q \
    "PUT file://${INPUT_DIR}/${table}.psv ${STAGE_PATH}/${table}/ AUTO_COMPRESS=FALSE OVERWRITE=FALSE;"
  echo "Loading hartford.${table} ..."
  "${SNOWSQL_COMMON[@]}" -q \
    "COPY INTO hartford.${table} FROM ${STAGE_PATH}/${table}/ FILE_FORMAT=(FORMAT_NAME='${FILE_FORMAT}') ON_ERROR='ABORT_STATEMENT';"
done

echo "Snowflake stage load complete."
