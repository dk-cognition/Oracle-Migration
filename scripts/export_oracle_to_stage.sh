#!/usr/bin/env bash
# ============================================================================
# export_oracle_to_stage.sh
#
# Legacy nightly extract: dumps Oracle tables to pipe-delimited flat files with
# SQL*Plus, then hands them off to the warehouse feed. This is the pattern the
# Snowflake migration replaces with COPY INTO from a cloud stage / Snowpipe.
#
# Data governance: the warehouse feed does not receive raw PII. Each table has
# an explicit projection (no SELECT *, so a schema change cannot silently widen
# the extract) and the customer projection masks ssn / date_of_birth / email /
# phone. Output files are written under a 0700 directory with 0600 files.
#
# Usage: ORACLE_APP_PASSWORD=*** ./export_oracle_to_stage.sh /path/to/outdir
# ============================================================================
set -euo pipefail

# Extract files contain (masked) customer data: never group/world readable.
umask 077

OUT_DIR="${1:-./extract}"
DB_USER="${DB_USER:-hartford_app}"
DB_TNS="${DB_TNS:-HRTFD_PROD}"
: "${ORACLE_APP_PASSWORD:?Set ORACLE_APP_PASSWORD}"

mkdir -p "${OUT_DIR}"
chmod 700 "${OUT_DIR}"

TABLES=(customer agent policy claim claim_payment)

# Explicit, non-sensitive projections per table. ssn is reduced to its last four
# digits, date_of_birth to the birth year, and email/phone to a coarse form that
# still supports downstream analytics without disclosing contact details.
projection_for() {
  case "$1" in
    customer)
      cat <<'PROJ'
    SELECT customer_id
         , first_name
         , last_name
         , CASE WHEN ssn IS NULL THEN NULL
                ELSE 'XXX-XX-' || SUBSTR(ssn, -4)
           END                                         AS ssn_last4
         , TO_CHAR(date_of_birth, 'YYYY')              AS birth_year
         , CASE WHEN email IS NULL THEN NULL
                ELSE SUBSTR(email, INSTR(email, '@'))
           END                                         AS email_domain
         , CASE WHEN phone IS NULL THEN NULL
                ELSE SUBSTR(REGEXP_REPLACE(phone, '[^0-9]', ''), 1, 3)
           END                                         AS phone_area_code
         , TO_CHAR(created_ts, 'YYYY-MM-DD HH24:MI:SS') AS created_ts
         , TO_CHAR(updated_ts, 'YYYY-MM-DD HH24:MI:SS') AS updated_ts
         , risk_score
         , lifetime_premium
      FROM hartford.customer;
PROJ
      ;;
    agent)
      cat <<'PROJ'
    SELECT agent_id
         , agent_name
         , manager_id
         , region_code
         , TO_CHAR(hire_date, 'YYYY-MM-DD') AS hire_date
      FROM hartford.agent;
PROJ
      ;;
    policy)
      cat <<'PROJ'
    SELECT policy_id
         , policy_number
         , customer_id
         , agent_id
         , product_code
         , status
         , TO_CHAR(effective_date, 'YYYY-MM-DD')        AS effective_date
         , TO_CHAR(expiration_date, 'YYYY-MM-DD')       AS expiration_date
         , annual_premium
         , coverage_limit
         , deductible
         , TO_CHAR(created_ts, 'YYYY-MM-DD HH24:MI:SS') AS created_ts
      FROM hartford.policy;
PROJ
      ;;
    claim)
      cat <<'PROJ'
    SELECT claim_id
         , claim_number
         , policy_id
         , TO_CHAR(loss_date, 'YYYY-MM-DD')                AS loss_date
         , TO_CHAR(reported_date, 'YYYY-MM-DD HH24:MI:SS')  AS reported_date
         , claim_type
         , status
         , reserve_amount
         , paid_amount
         , adjuster_id
      FROM hartford.claim;
PROJ
      ;;
    claim_payment)
      cat <<'PROJ'
    SELECT payment_id
         , claim_id
         , TO_CHAR(payment_date, 'YYYY-MM-DD HH24:MI:SS') AS payment_date
         , amount
         , payment_method
      FROM hartford.claim_payment;
PROJ
      ;;
    *)
      echo "No approved projection defined for table '$1'" >&2
      return 1
      ;;
  esac
}

for t in "${TABLES[@]}"; do
  echo "Exporting hartford.${t} ..."
  projection="$(projection_for "${t}")"
  sqlplus -s "${DB_USER}/${ORACLE_APP_PASSWORD}@${DB_TNS}" <<SQL
    SET PAGESIZE 0
    SET FEEDBACK OFF
    SET COLSEP '|'
    SET LINESIZE 32767
    SET TRIMSPOOL ON
    SPOOL ${OUT_DIR}/${t}.psv
${projection}
    SPOOL OFF
    EXIT
SQL
  chmod 600 "${OUT_DIR}/${t}.psv"
done

echo "Done. Flat files in ${OUT_DIR}"
echo "TODO (migration): replace this with 'COPY INTO @claims_stage/... FROM ...'"
