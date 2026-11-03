#!/usr/bin/env bash
# ============================================================================
# unload_to_stage.sh
#
# Nightly full-table snapshot for the warehouse feed, Snowflake-native:
# each table is unloaded server-side with COPY INTO @stage. Replaces
# export_oracle_to_stage.sh (SQL*Plus spool to local .psv files + SFTP).
# Stage and file format are created by db/snowflake/05_etl_stage.sql.
#
# Usage: ./unload_to_stage.sh [@stage]
#
# Environment:
#   SNOWFLAKE_CONNECTION  Snowflake CLI connection name in ~/.snowflake/config.toml
#                         (default: hartford_claims). Credentials live there, not here.
#   SNOWFLAKE_SCHEMA      schema to unload (default: HARTFORD.CLAIMS)
#   FILE_FORMAT           named file format (default: claims_psv_ff)
#   RUN_DATE              partition folder, YYYY-MM-DD (default: today, UTC)
#   DRY_RUN=1             print the SQL instead of executing it
# ============================================================================
set -euo pipefail

STAGE="${1:-@claims_extract_stage/snapshot}"
STAGE="${STAGE%/}"
CONNECTION="${SNOWFLAKE_CONNECTION:-hartford_claims}"
SCHEMA="${SNOWFLAKE_SCHEMA:-HARTFORD.CLAIMS}"
FILE_FORMAT="${FILE_FORMAT:-claims_psv_ff}"
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
  SQL+=$'\n'"COPY INTO ${STAGE}/${RUN_DATE}/${t}/${t}_ FROM ${t} FILE_FORMAT = (FORMAT_NAME = '${FILE_FORMAT}') HEADER = FALSE OVERWRITE = TRUE;"
done

if [[ "${DRY_RUN:-0}" == "1" ]]; then
  echo "${SQL}"
  exit 0
fi

command -v snow >/dev/null 2>&1 || { echo "Snowflake CLI ('snow') not found on PATH" >&2; exit 1; }

echo "Unloading ${#TABLES[@]} tables to ${STAGE}/${RUN_DATE}/ ..."
snow sql --connection "${CONNECTION}" --query "${SQL}"
echo "Done. Files are under ${STAGE}/${RUN_DATE}/<table>/"
