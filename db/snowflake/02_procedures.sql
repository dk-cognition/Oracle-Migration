--------------------------------------------------------------------------------
-- The Hartford - Claims Data Store
-- Snowflake Scripting procedures / UDFs, migrated from db/oracle/02_packages.sql.
--
-- Snowflake has no packages, so each claims_pkg program unit becomes its own
-- top-level object (docs/MIGRATION.md section 4):
--   claims_pkg.open_claim          -> PROCEDURE sp_open_claim
--   claims_pkg.post_payment        -> PROCEDURE sp_post_payment
--   claims_pkg.loss_ratio          -> FUNCTION  fn_loss_ratio
--   claims_pkg.g_default_reserve   -> FUNCTION  fn_default_reserve (claims_config)
--   fn_customer_full_name          -> FUNCTION  fn_customer_full_name
-- RAISE_APPLICATION_ERROR becomes a Scripting EXCEPTION + RAISE, and
-- "RETURNING ... INTO" is replaced by an explicit re-query.
--------------------------------------------------------------------------------

USE SCHEMA hartford.claims;

--------------------------------------------------------------------------------
-- Package constant g_default_reserve, sourced from the claims_config table so
-- it can be changed without redeploying code.
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION hartford.claims.fn_default_reserve()
  RETURNS NUMBER(14,2)
AS
$$
  SELECT TO_NUMBER(config_value, 14, 2)
    FROM hartford.claims.claims_config
   WHERE config_key = 'DEFAULT_RESERVE'
$$;

--------------------------------------------------------------------------------
-- fn_customer_full_name: NO_DATA_FOUND handling is implicit - a scalar subquery
-- over zero rows already yields NULL.
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION hartford.claims.fn_customer_full_name(p_customer_id NUMBER)
  RETURNS VARCHAR
AS
$$
  SELECT last_name || ', ' || first_name
    FROM hartford.claims.customer
   WHERE customer_id = p_customer_id
$$;

--------------------------------------------------------------------------------
-- loss_ratio: total paid / annual premium, guarded against divide-by-zero.
-- DECODE + NVL replaced by CASE + COALESCE.
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION hartford.claims.fn_loss_ratio(p_policy_id NUMBER)
  RETURNS NUMBER(38,4)
AS
$$
  SELECT CASE
           WHEN COALESCE(p.annual_premium, 0) = 0 THEN 0
           ELSE ROUND(
                  COALESCE((SELECT SUM(c.paid_amount)
                              FROM hartford.claims.claim c
                             WHERE c.policy_id = p.policy_id), 0) / p.annual_premium, 4)
         END
    FROM hartford.claims.policy p
   WHERE p.policy_id = p_policy_id
$$;

--------------------------------------------------------------------------------
-- open_claim: books a claim and returns the generated claim_id.
-- The Oracle version read seq_claim_id.NEXTVAL from DUAL; Snowflake drops the
-- FROM dual and the value is bound explicitly so the id can be returned.
--------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE hartford.claims.sp_open_claim(
    p_policy_id  NUMBER,
    p_loss_date  TIMESTAMP_NTZ,
    p_claim_type VARCHAR,
    p_description VARCHAR)
  RETURNS NUMBER(12,0)
  LANGUAGE SQL
AS
$$
DECLARE
  v_claim_id     NUMBER(12,0);
  v_claim_number VARCHAR;
  v_existing     NUMBER;
  duplicate_claim_number EXCEPTION (-20001, 'Duplicate claim number generated');
BEGIN
  SELECT hartford.claims.seq_claim_id.NEXTVAL INTO :v_claim_id;

  v_claim_number := 'CLM-' || TO_VARCHAR(CURRENT_TIMESTAMP(), 'YYYY') || '-' ||
                    LPAD(TO_VARCHAR(:v_claim_id), 10, '0');

  -- Snowflake does not enforce the UNIQUE constraint on claim_number, so the
  -- Oracle DUP_VAL_ON_INDEX handler becomes an explicit pre-check.
  SELECT COUNT(*) INTO :v_existing
    FROM hartford.claims.claim
   WHERE claim_number = :v_claim_number;

  IF (v_existing > 0) THEN
    RAISE duplicate_claim_number;
  END IF;

  INSERT INTO hartford.claims.claim (
    claim_id, claim_number, policy_id, loss_date, reported_date,
    claim_type, status, reserve_amount, paid_amount, description
  ) VALUES (
    :v_claim_id, :v_claim_number, :p_policy_id, :p_loss_date, CURRENT_TIMESTAMP(),
    :p_claim_type, 'OPEN', hartford.claims.fn_default_reserve(), 0, :p_description
  );

  RETURN v_claim_id;
END;
$$;

--------------------------------------------------------------------------------
-- post_payment: records a payment, rolls it into claim.paid_amount, and closes
-- the claim once payments meet the reserve.
--
-- Differences from the PL/SQL original:
--   * seq_payment_id.NEXTVAL is taken from the column DEFAULT.
--   * UPDATE ... RETURNING ... INTO is unsupported -> re-query after the update.
--   * No explicit COMMIT: each statement in an unscoped procedure autocommits.
--------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE hartford.claims.sp_post_payment(
    p_claim_id NUMBER,
    p_amount   NUMBER,
    p_method   VARCHAR,
    p_check_no VARCHAR)
  RETURNS VARCHAR
  LANGUAGE SQL
AS
$$
DECLARE
  v_reserve NUMBER(14,2);
  v_paid    NUMBER(14,2);
  unknown_claim EXCEPTION (-20002, 'Unknown claim_id');
BEGIN
  SELECT COUNT(*) INTO :v_paid
    FROM hartford.claims.claim
   WHERE claim_id = :p_claim_id;

  IF (v_paid = 0) THEN
    RAISE unknown_claim;
  END IF;

  INSERT INTO hartford.claims.claim_payment (
    claim_id, payment_date, amount, payment_method, check_number
  ) VALUES (
    :p_claim_id, CURRENT_TIMESTAMP(), :p_amount, :p_method, :p_check_no
  );

  UPDATE hartford.claims.claim
     SET paid_amount = paid_amount + :p_amount
   WHERE claim_id = :p_claim_id;

  SELECT reserve_amount, paid_amount
    INTO :v_reserve, :v_paid
    FROM hartford.claims.claim
   WHERE claim_id = :p_claim_id;

  IF (v_paid >= v_reserve) THEN
    UPDATE hartford.claims.claim
       SET status = 'CLOSED'
     WHERE claim_id = :p_claim_id;
    RETURN 'CLOSED';
  END IF;

  RETURN 'OPEN';
END;
$$;
