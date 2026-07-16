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

# Explicit, per-table column projections for the downstream warehouse feed.
# NEVER "SELECT *" here: it would spool regulated PII to a plaintext flat file.
# The customer projection deliberately omits the regulated PII columns `ssn`
# and `date_of_birth`; customer_id is the stable join key the feed uses.
declare -A COLUMNS=(
  [customer]="customer_id, first_name, last_name, email, phone, created_ts, updated_ts, risk_score, lifetime_premium, notes"
  [agent]="agent_id, agent_name, manager_id, region_code, hire_date"
  [policy]="policy_id, policy_number, customer_id, agent_id, product_code, status, effective_date, expiration_date, annual_premium, coverage_limit, deductible, created_ts"
  [claim]="claim_id, claim_number, policy_id, loss_date, reported_date, claim_type, status, reserve_amount, paid_amount, adjuster_id, description"
  [claim_payment]="payment_id, claim_id, payment_date, amount, payment_method, check_number"
)

for t in "${TABLES[@]}"; do
  if [[ -z "${COLUMNS[$t]:-}" ]]; then
    echo "Refusing to export hartford.${t}: no explicit column projection defined." >&2
    exit 1
  fi
  echo "Exporting hartford.${t} ..."
  sqlplus -s "${DB_USER}/${ORACLE_APP_PASSWORD}@${DB_TNS}" <<SQL
    SET PAGESIZE 0
    SET FEEDBACK OFF
    SET COLSEP '|'
    SET LINESIZE 32767
    SET TRIMSPOOL ON
    SPOOL ${OUT_DIR}/${t}.psv
    SELECT ${COLUMNS[$t]} FROM hartford.${t};
    SPOOL OFF
    EXIT
SQL
done

echo "Done. Flat files in ${OUT_DIR}"
echo "TODO (migration): replace this with 'COPY INTO @claims_stage/... FROM ...'"
