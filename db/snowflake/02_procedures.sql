--------------------------------------------------------------------------------
-- The Hartford - Claims Data Store
-- claims_pkg re-implemented as standalone Snowflake Scripting procedures and
-- SQL UDFs, migrated from db/oracle/02_packages.sql.
--
-- Snowflake has no packages, so each program unit is its own object:
--   claims_pkg.g_default_reserve  -> FUNCTION  claims_default_reserve()
--   claims_pkg.open_claim         -> PROCEDURE open_claim(...)   RETURNS NUMBER
--                                    (a UDF cannot run DML, so it is a procedure)
--   claims_pkg.post_payment       -> PROCEDURE post_payment(...) RETURNS VARCHAR
--   claims_pkg.loss_ratio         -> FUNCTION  loss_ratio(...)
--   fn_customer_full_name         -> FUNCTION  fn_customer_full_name(...)
--   trg_customer_biu / trg_policy_bi -> column DEFAULTs in 01_schema.sql
--
-- Behaviour notes:
--   * RAISE_APPLICATION_ERROR -> declared EXCEPTION (codes -20001..-20003) + RAISE.
--   * DUP_VAL_ON_INDEX and FK violations never fire in Snowflake (constraints
--     are not enforced), so the procedures check uniqueness / parent rows
--     explicitly before writing.
--   * UPDATE ... RETURNING INTO is unsupported; post_payment folds the
--     auto-close rule into the UPDATE itself and re-queries the result.
--------------------------------------------------------------------------------

USE SCHEMA hartford.claims;

--------------------------------------------------------------------------------
-- Package constant g_default_reserve.
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION hartford.claims.claims_default_reserve()
  RETURNS NUMBER(14,2)
  AS
  $$
    2500
  $$;

--------------------------------------------------------------------------------
-- open_claim: book a new claim and return the generated claim_id.
--------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE hartford.claims.open_claim(
    p_policy_id   NUMBER,
    p_loss_date   TIMESTAMP_NTZ,
    p_claim_type  VARCHAR,
    p_description VARCHAR
  )
  RETURNS NUMBER(12,0)
  LANGUAGE SQL
  EXECUTE AS OWNER
AS
$$
DECLARE
  v_claim_id     NUMBER(12,0);
  v_claim_number VARCHAR(24);
  v_exists       BOOLEAN;
  dup_claim_number EXCEPTION (-20001, 'Duplicate claim number generated');
  unknown_policy   EXCEPTION (-20002, 'Policy does not exist');
BEGIN
  v_exists := (SELECT COUNT(*) > 0 FROM hartford.claims.policy WHERE policy_id = :p_policy_id);
  IF (NOT v_exists) THEN
    RAISE unknown_policy;
  END IF;

  v_claim_id := (SELECT hartford.claims.seq_claim_id.NEXTVAL);
  v_claim_number := 'CLM-' || TO_VARCHAR(CURRENT_TIMESTAMP(), 'YYYY') || '-' ||
                    LPAD(TO_VARCHAR(v_claim_id), 10, '0');

  v_exists := (SELECT COUNT(*) > 0 FROM hartford.claims.claim WHERE claim_number = :v_claim_number);
  IF (v_exists) THEN
    RAISE dup_claim_number;
  END IF;

  INSERT INTO hartford.claims.claim (
    claim_id, claim_number, policy_id, loss_date, reported_date,
    claim_type, status, reserve_amount, paid_amount, description
  ) VALUES (
    :v_claim_id, :v_claim_number, :p_policy_id, :p_loss_date, CURRENT_TIMESTAMP(),
    :p_claim_type, 'OPEN', hartford.claims.claims_default_reserve(), 0, :p_description
  );

  RETURN v_claim_id;
END;
$$;

--------------------------------------------------------------------------------
-- post_payment: record a payment, add it to paid_amount and auto-close the
-- claim once payments meet/exceed the reserve. Returns the claim's new status.
--------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE hartford.claims.post_payment(
    p_claim_id NUMBER,
    p_amount   NUMBER(14,2),
    p_method   VARCHAR,
    p_check_no VARCHAR DEFAULT NULL
  )
  RETURNS VARCHAR
  LANGUAGE SQL
  EXECUTE AS OWNER
AS
$$
DECLARE
  v_exists BOOLEAN;
  v_status VARCHAR(16);
  unknown_claim EXCEPTION (-20003, 'Claim does not exist');
BEGIN
  v_exists := (SELECT COUNT(*) > 0 FROM hartford.claims.claim WHERE claim_id = :p_claim_id);
  IF (NOT v_exists) THEN
    RAISE unknown_claim;
  END IF;

  BEGIN TRANSACTION;

  INSERT INTO hartford.claims.claim_payment (
    claim_id, payment_date, amount, payment_method, check_number
  ) VALUES (
    :p_claim_id, CURRENT_TIMESTAMP(), :p_amount, :p_method, :p_check_no
  );

  UPDATE hartford.claims.claim
     SET paid_amount = paid_amount + :p_amount,
         status      = IFF(paid_amount + :p_amount >= reserve_amount, 'CLOSED', status)
   WHERE claim_id = :p_claim_id;

  COMMIT;

  v_status := (SELECT status FROM hartford.claims.claim WHERE claim_id = :p_claim_id);
  RETURN v_status;
EXCEPTION
  WHEN OTHER THEN
    ROLLBACK;
    RAISE;
END;
$$;

--------------------------------------------------------------------------------
-- loss_ratio: total paid / annual premium, 0 when premium is 0/NULL.
-- Returns NULL for an unknown policy (Oracle raised NO_DATA_FOUND).
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION hartford.claims.loss_ratio(p_policy_id NUMBER)
  RETURNS NUMBER(18,4)
  AS
  $$
    SELECT IFF(COALESCE(MAX(p.annual_premium), 0) = 0,
               0,
               ROUND(COALESCE(SUM(c.paid_amount), 0) / MAX(p.annual_premium), 4))
      FROM hartford.claims.policy p
      LEFT JOIN hartford.claims.claim c
        ON c.policy_id = p.policy_id
     WHERE p.policy_id = p_policy_id
    HAVING COUNT(p.policy_id) > 0
  $$;

--------------------------------------------------------------------------------
-- fn_customer_full_name: "Last, First"; NULL when the customer is unknown.
-- COALESCE keeps Oracle's NULL-as-empty-string || semantics.
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION hartford.claims.fn_customer_full_name(p_customer_id NUMBER)
  RETURNS VARCHAR(200)
  AS
  $$
    SELECT COALESCE(last_name, '') || ', ' || COALESCE(first_name, '')
      FROM hartford.claims.customer
     WHERE customer_id = p_customer_id
  $$;
