--------------------------------------------------------------------------------
-- The Hartford - Claims Data Store
-- Snowflake procedures/functions, migrated from the Oracle claims_pkg package
-- and standalone units in db/oracle/02_packages.sql.
--
-- Snowflake has no packages: each program unit becomes its own procedure or
-- function. Package state (g_default_reserve) becomes a scalar UDF.
--   * claims_pkg.open_claim    -> PROCEDURE sp_open_claim (returns claim_id)
--   * claims_pkg.post_payment  -> PROCEDURE sp_post_payment
--   * claims_pkg.loss_ratio    -> FUNCTION  fn_loss_ratio
--   * g_default_reserve        -> FUNCTION  fn_default_reserve
--   * fn_customer_full_name    -> FUNCTION  fn_customer_full_name
-- Trigger logic (trg_customer_biu, trg_policy_bi) is re-expressed as column
-- DEFAULTs in 01_schema.sql plus Streams + Tasks in 04_streams_tasks.sql.
--------------------------------------------------------------------------------

USE SCHEMA hartford;

--------------------------------------------------------------------------------
-- Package constant g_default_reserve -> scalar UDF.
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION hartford.fn_default_reserve()
  RETURNS NUMBER(14,2)
AS
$$
  2500
$$;

--------------------------------------------------------------------------------
-- claims_pkg.open_claim: book a new claim and return the generated claim_id.
-- RETURNING/DUP_VAL_ON_INDEX are unavailable; the id comes from the sequence
-- before the INSERT, and uniqueness violations surface as STATEMENT_ERROR.
--------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE hartford.sp_open_claim (
  p_policy_id   NUMBER,
  p_loss_date   TIMESTAMP_NTZ,
  p_claim_type  VARCHAR,
  p_description VARCHAR
)
RETURNS NUMBER
LANGUAGE SQL
AS
$$
DECLARE
  v_claim_id     NUMBER;
  v_claim_number VARCHAR(24);
BEGIN
  -- No DUAL in Snowflake: SELECT seq.NEXTVAL directly.
  SELECT hartford.seq_claim_id.NEXTVAL INTO :v_claim_id;

  v_claim_number := 'CLM-' || TO_VARCHAR(CURRENT_TIMESTAMP(), 'YYYY') || '-' ||
                    LPAD(TO_VARCHAR(:v_claim_id), 10, '0');

  INSERT INTO hartford.claim (
    claim_id, claim_number, policy_id, loss_date, reported_date,
    claim_type, status, reserve_amount, paid_amount, description
  ) VALUES (
    :v_claim_id, :v_claim_number, :p_policy_id, :p_loss_date, CURRENT_TIMESTAMP(),
    :p_claim_type, 'OPEN', hartford.fn_default_reserve(), 0, :p_description
  );

  RETURN v_claim_id;
END;
$$;

--------------------------------------------------------------------------------
-- claims_pkg.post_payment: post a payment, update paid_amount, auto-close when
-- payments meet/exceed the reserve. Oracle RETURNING ... INTO is not supported:
-- re-query the claim after the UPDATE instead.
--------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE hartford.sp_post_payment (
  p_claim_id NUMBER,
  p_amount   NUMBER,
  p_method   VARCHAR,
  p_check_no VARCHAR DEFAULT NULL
)
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
DECLARE
  v_reserve NUMBER(14,2);
  v_paid    NUMBER(14,2);
BEGIN
  INSERT INTO hartford.claim_payment (
    claim_id, payment_date, amount, payment_method, check_number
  ) VALUES (
    :p_claim_id, CURRENT_TIMESTAMP(), :p_amount, :p_method, :p_check_no
  );

  UPDATE hartford.claim
     SET paid_amount = paid_amount + :p_amount
   WHERE claim_id = :p_claim_id;

  SELECT reserve_amount, paid_amount
    INTO :v_reserve, :v_paid
    FROM hartford.claim
   WHERE claim_id = :p_claim_id;

  IF (v_paid >= v_reserve) THEN
    UPDATE hartford.claim
       SET status = 'CLOSED'
     WHERE claim_id = :p_claim_id;
  END IF;

  RETURN 'OK';
END;
$$;

--------------------------------------------------------------------------------
-- claims_pkg.loss_ratio: total paid / annual premium for a policy.
-- DECODE(NVL(...)) divide-by-zero guard -> CASE / COALESCE / NULLIF.
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION hartford.fn_loss_ratio (p_policy_id NUMBER)
  RETURNS NUMBER(14,4)
AS
$$
  SELECT COALESCE(
           ROUND(
             COALESCE((SELECT SUM(c.paid_amount)
                         FROM hartford.claim c
                        WHERE c.policy_id = p_policy_id), 0)
             / NULLIF((SELECT p.annual_premium
                         FROM hartford.policy p
                        WHERE p.policy_id = p_policy_id), 0),
             4),
           0)
$$;

--------------------------------------------------------------------------------
-- fn_customer_full_name: NO_DATA_FOUND -> NULL happens naturally with a
-- scalar subquery.
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION hartford.fn_customer_full_name (p_customer_id NUMBER)
  RETURNS VARCHAR(200)
AS
$$
  SELECT last_name || ', ' || first_name
    FROM hartford.customer
   WHERE customer_id = p_customer_id
$$;
