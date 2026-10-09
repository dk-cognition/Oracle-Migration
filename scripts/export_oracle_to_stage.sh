#!/usr/bin/env bash
# ============================================================================
# export_oracle_to_stage.sh
#
# Nightly full-table extract, now Snowflake-native: unloads each table to a
# Snowflake stage with COPY INTO (no SQL*Plus spool, no flat-file SFTP hop).
# Stage and file format are created by db/snowflake/05_etl_stage.sql.
#
# Usage: ./export_oracle_to_stage.sh [@stage]
#
# Environment:
#   SNOWFLAKE_CONNECTION  Snowflake CLI connection name (default: hartford_claims),
#                         defined in ~/.snowflake/config.toml
#   SNOWFLAKE_SCHEMA      schema to read from (default: HARTFORD.CLAIMS)
#   FILE_FORMAT           named file format (default: psv_format)
#   RUN_DATE              partition folder, YYYY-MM-DD (default: today, UTC)
#   DRY_RUN=1             print the SQL instead of executing it
# ============================================================================
set -euo pipefail

STAGE="${1:-@claims_extract_stage}"
STAGE="${STAGE%/}"
CONNECTION="${SNOWFLAKE_CONNECTION:-hartford_claims}"
SCHEMA="${SNOWFLAKE_SCHEMA:-HARTFORD.CLAIMS}"
FILE_FORMAT="${FILE_FORMAT:-psv_format}"
RUN_DATE="${RUN_DATE:-$(date -u +%F)}"

if [[ ! "${STAGE}" =~ ^@[A-Za-z0-9_\$./~-]+$ ]]; then
  echo "Invalid stage reference: ${STAGE}" >&2
  exit 2
fi
if [[ ! "${SCHEMA}" =~ ^[A-Za-z0-9_\$.]+$ || ! "${FILE_FORMAT}" =~ ^[A-Za-z0-9_\$.]+$ ]]; then
  echo "Invalid schema or file format name" >&2
  exit 2
fi
if [[ ! "${RUN_DATE}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  echo "RUN_DATE must be YYYY-MM-DD" >&2
  exit 2
fi

TABLES=(customer agent policy claim claim_payment)

SQL="USE SCHEMA ${SCHEMA};"
for t in "${TABLES[@]}"; do
  SQL+=$'\n'"COPY INTO ${STAGE}/${t}/${RUN_DATE}/${t}_ FROM ${t} FILE_FORMAT = (FORMAT_NAME = '${FILE_FORMAT}') HEADER = FALSE OVERWRITE = TRUE;"
done

if [[ "${DRY_RUN:-0}" == "1" ]]; then
  echo "${SQL}"
  exit 0
fi

command -v snow >/dev/null 2>&1 || { echo "Snowflake CLI ('snow') not found on PATH" >&2; exit 1; }

echo "Unloading ${#TABLES[@]} tables to ${STAGE} (run date ${RUN_DATE}) ..."
snow sql --connection "${CONNECTION}" --query "${SQL}"
echo "Done. Files are under ${STAGE}/<table>/${RUN_DATE}/"
