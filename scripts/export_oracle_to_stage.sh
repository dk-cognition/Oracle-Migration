#!/usr/bin/env bash
# ============================================================================
# export_oracle_to_stage.sh
#
# Legacy nightly extract: dumps Oracle tables to pipe-delimited flat files with
# SQL*Plus, then hands them off to the warehouse feed. This is the pattern the
# Snowflake migration replaces with COPY INTO from a cloud stage / Snowpipe.
#
# Usage: ORACLE_APP_PASSWORD=*** ./export_oracle_to_stage.sh /path/to/outdir
# ============================================================================
set -euo pipefail

OUT_DIR="${1:-./extract}"
DB_USER="${DB_USER:-hartford_app}"
DB_TNS="${DB_TNS:-HRTFD_PROD}"
: "${ORACLE_APP_PASSWORD:?Set ORACLE_APP_PASSWORD}"

mkdir -p "${OUT_DIR}"

TABLES=(customer agent policy claim claim_payment)

for t in "${TABLES[@]}"; do
  echo "Exporting hartford.${t} ..."
  sqlplus -s "${DB_USER}/${ORACLE_APP_PASSWORD}@${DB_TNS}" <<SQL
    SET PAGESIZE 0
    SET FEEDBACK OFF
    SET COLSEP '|'
    SET LINESIZE 32767
    SET TRIMSPOOL ON
    SPOOL ${OUT_DIR}/${t}.psv
    SELECT * FROM hartford.${t};
    SPOOL OFF
    EXIT
SQL
done

echo "Done. Flat files in ${OUT_DIR}"
echo "TODO (migration): replace this with 'COPY INTO @claims_stage/... FROM ...'"
