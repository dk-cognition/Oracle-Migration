#!/usr/bin/env bash
# ============================================================================
# export_oracle_to_stage.sh
#
# Legacy nightly extract: dumps Oracle tables to pipe-delimited flat files with
# SQL*Plus, then hands them off to the warehouse feed. This is the pattern the
# Snowflake migration replaces with COPY INTO from a cloud stage / Snowpipe.
#
# Each table has an explicit, PII-minimized projection (see PROJECTIONS below):
# regulated columns are never spooled in the clear. SSN is reduced to its last
# four digits and date_of_birth to the birth year, which is what the warehouse
# feed actually consumes. If a downstream consumer needs full values, tokenize
# them in the database first -- do not widen the projection here.
#
# Usage: ORACLE_APP_PASSWORD=*** ./export_oracle_to_stage.sh /path/to/outdir
# ============================================================================
set -euo pipefail

# Owner-only permissions on everything this script creates (extracts are
# sensitive even after PII minimization).
umask 0077

OUT_DIR="${1:-./extract}"
DB_USER="${DB_USER:-hartford_app}"
DB_TNS="${DB_TNS:-HRTFD_PROD}"
: "${ORACLE_APP_PASSWORD:?Set ORACLE_APP_PASSWORD}"

mkdir -p "${OUT_DIR}"
chmod 0700 "${OUT_DIR}"

TABLES=(customer agent policy claim claim_payment)

# Explicit column projections, keyed by table. Never use SELECT *.
declare -A PROJECTIONS
PROJECTIONS[customer]="customer_id, first_name, last_name,
             SUBSTR(ssn, -4)              AS ssn_last4,
             TO_CHAR(date_of_birth,'YYYY') AS birth_year,
             email, phone, created_ts, updated_ts, risk_score,
             lifetime_premium"
PROJECTIONS[agent]="agent_id, agent_name, manager_id, region_code, hire_date"
PROJECTIONS[policy]="policy_id, policy_number, customer_id, agent_id, product_code,
             status, effective_date, expiration_date, annual_premium,
             coverage_limit, deductible, created_ts"
PROJECTIONS[claim]="claim_id, claim_number, policy_id, loss_date, reported_date,
             claim_type, status, reserve_amount, paid_amount, adjuster_id"
PROJECTIONS[claim_payment]="payment_id, claim_id, payment_date, amount, payment_method"

for t in "${TABLES[@]}"; do
  cols="${PROJECTIONS[$t]:-}"
  if [[ -z "${cols}" ]]; then
    echo "No column projection defined for hartford.${t}; refusing to export." >&2
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
    SELECT ${cols} FROM hartford.${t};
    SPOOL OFF
    EXIT
SQL
  if [[ -f "${OUT_DIR}/${t}.psv" ]]; then
    chmod 0600 "${OUT_DIR}/${t}.psv"
  fi
done

echo "Done. Flat files in ${OUT_DIR}"
echo "Transfer these files only over an encrypted channel (SFTP/SCP) to an"
echo "access-controlled landing zone; encrypt at rest before any long-term copy."
echo "TODO (migration): replace this with 'COPY INTO @claims_stage/... FROM ...'"
