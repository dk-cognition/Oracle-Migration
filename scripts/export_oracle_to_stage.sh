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

# Allowlisted staging root. All extract output must live inside this directory.
# Override with STAGE_ROOT to relocate the staging area, but the resolved output
# directory is always confined to it so a caller-supplied argument cannot direct
# writes to an arbitrary filesystem location (path traversal / arbitrary write).
STAGE_ROOT="${STAGE_ROOT:-$(pwd)/extract}"
mkdir -p "${STAGE_ROOT}"
STAGE_ROOT="$(cd "${STAGE_ROOT}" && pwd -P)"

# Canonicalize the requested output directory (default: the staging root itself)
# without requiring it to exist yet, then fail closed if it escapes STAGE_ROOT.
REQUESTED_OUT_DIR="${1:-${STAGE_ROOT}}"
OUT_DIR="$(realpath -m -- "${REQUESTED_OUT_DIR}")"
case "${OUT_DIR}/" in
  "${STAGE_ROOT}/"*) ;;
  *)
    echo "ERROR: output directory '${REQUESTED_OUT_DIR}' resolves to '${OUT_DIR}'," >&2
    echo "       which is outside the staging root '${STAGE_ROOT}'. Refusing to run." >&2
    exit 1
    ;;
esac

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
    SPOOL "${OUT_DIR}/${t}.psv"
    SELECT * FROM hartford.${t};
    SPOOL OFF
    EXIT
SQL
done

echo "Done. Flat files in ${OUT_DIR}"
echo "TODO (migration): replace this with 'COPY INTO @claims_stage/... FROM ...'"
