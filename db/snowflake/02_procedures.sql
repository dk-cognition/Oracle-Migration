--------------------------------------------------------------------------------
-- The Hartford - Claims Data Store
-- claims_pkg re-implemented for Snowflake, migrated from Oracle PL/SQL.
--
-- Snowflake has no packages: each program unit of hartford.claims_pkg becomes
-- its own CREATE PROCEDURE (Snowflake Scripting) or CREATE FUNCTION (SQL UDF).
--   * claims_pkg.open_claim        -> sp_open_claim (procedure)
--   * claims_pkg.post_payment      -> sp_post_payment (procedure)
--   * claims_pkg.loss_ratio        -> fn_loss_ratio (SQL UDF)
--   * claims_pkg.g_default_reserve -> fn_default_reserve (scalar UDF)
--   * fn_customer_full_name        -> fn_customer_full_name (SQL UDF)
--   * RAISE_APPLICATION_ERROR      -> Snowflake Scripting EXCEPTION / RAISE
--   * RETURNING ... INTO           -> re-query after the UPDATE
-- Trigger / MV-refresh logic lives in 04_streams_tasks.sql.
--------------------------------------------------------------------------------

USE SCHEMA hartford.claims;

--------------------------------------------------------------------------------
-- Package constant g_default_reserve -> scalar UDF.
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_default_reserve()
  RETURNS NUMBER(14,2)
AS
$$
  2500
$$;

--------------------------------------------------------------------------------
-- claims_pkg.open_claim -> sp_open_claim
-- Books a new claim and returns the generated claim_id.
--------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_open_claim (
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
  v_claim_id      NUMBER;
  v_claim_number  VARCHAR(24);
  duplicate_claim EXCEPTION (-20001, 'Duplicate claim number generated.');
BEGIN
  v_claim_id := (SELECT seq_claim_id.NEXTVAL);

  v_claim_number := 'CLM-' || TO_VARCHAR(CURRENT_TIMESTAMP(), 'YYYY') || '-' ||
                    LPAD(TO_VARCHAR(:v_claim_id), 10, '0');

  -- Snowflake does not enforce UNIQUE constraints (no DUP_VAL_ON_INDEX):
  -- check explicitly before inserting.
  IF (EXISTS (SELECT 1 FROM claim WHERE claim_number = :v_claim_number)) THEN
    RAISE duplicate_claim;
  END IF;

  INSERT INTO claim (
    claim_id, claim_number, policy_id, loss_date, reported_date,
    claim_type, status, reserve_amount, paid_amount, description
  )
  SELECT :v_claim_id, :v_claim_number, :p_policy_id, :p_loss_date, CURRENT_TIMESTAMP(),
         :p_claim_type, 'OPEN', fn_default_reserve(), 0, :p_description;

  RETURN v_claim_id;
END;
$$;

--------------------------------------------------------------------------------
-- claims_pkg.post_payment -> sp_post_payment
-- Posts a payment; updates paid_amount and auto-closes when fully paid.
-- Oracle RETURNING ... INTO has no Snowflake equivalent: re-query instead.
--------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_post_payment (
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
  INSERT INTO claim_payment (claim_id, payment_date, amount, payment_method, check_number)
  SELECT :p_claim_id, CURRENT_TIMESTAMP(), :p_amount, :p_method, :p_check_no;

  UPDATE claim
     SET paid_amount = paid_amount + :p_amount
   WHERE claim_id = :p_claim_id;

  SELECT reserve_amount, paid_amount
    INTO :v_reserve, :v_paid
    FROM claim
   WHERE claim_id = :p_claim_id;

  -- Auto-close when payments meet/exceed the reserve.
  IF (v_paid >= v_reserve) THEN
    UPDATE claim
       SET status = 'CLOSED'
     WHERE claim_id = :p_claim_id;
  END IF;

  RETURN 'OK';
END;
$$;

--------------------------------------------------------------------------------
-- claims_pkg.loss_ratio -> fn_loss_ratio (SQL UDF)
-- Loss ratio for a policy = total paid / annual premium (0 when premium is 0).
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_loss_ratio (p_policy_id NUMBER)
  RETURNS NUMBER(14,4)
AS
$$
  SELECT CASE
           WHEN COALESCE(p.annual_premium, 0) = 0 THEN 0
           ELSE ROUND(COALESCE(cl.total_paid, 0) / p.annual_premium, 4)
         END
    FROM policy p
    LEFT JOIN (SELECT policy_id, SUM(paid_amount) AS total_paid
                 FROM claim
                GROUP BY policy_id) cl
      ON cl.policy_id = p.policy_id
   WHERE p.policy_id = p_policy_id
$$;

--------------------------------------------------------------------------------
-- Standalone Oracle function fn_customer_full_name -> SQL UDF.
-- Returns NULL when the customer does not exist (Oracle NO_DATA_FOUND path).
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_customer_full_name (p_customer_id NUMBER)
  RETURNS VARCHAR(200)
AS
$$
  SELECT last_name || ', ' || first_name
    FROM customer
   WHERE customer_id = p_customer_id
$$;
