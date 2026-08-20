--------------------------------------------------------------------------------
-- The Hartford - Claims Data Store
-- Snowflake Scripting procedures / SQL UDFs, migrated from db/oracle/02_packages.sql.
--
-- Migration notes (see docs/MIGRATION.md):
--   * PL/SQL package claims_pkg has no Snowflake analog; each program unit is a
--     standalone CREATE PROCEDURE / CREATE FUNCTION.
--   * Package constant g_default_reserve -> scalar UDF fn_default_reserve.
--   * RAISE_APPLICATION_ERROR -> Snowflake Scripting EXCEPTION + RAISE.
--   * RETURNING ... INTO -> re-query after the UPDATE.
--   * The Oracle triggers (trg_customer_biu, trg_policy_bi) are replaced by
--     column defaults in 01_schema.sql; "on update" timestamps must be set by
--     the writing statement or a Stream+Task.
--   * Transaction boundaries: the explicit COMMIT in post_payment is dropped.
--     Snowflake procedures run inside the caller's transaction by default
--     (AUTOCOMMIT applies per statement from JDBC); the caller owns commits.
--------------------------------------------------------------------------------

USE SCHEMA hartford;

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
-- claims_pkg.open_claim -> procedure returning the generated claim_id.
--------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE open_claim(
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
  duplicate_claim EXCEPTION (-20001, 'Duplicate claim number generated.');
BEGIN
  -- Sequence NEXTVAL without DUAL.
  v_claim_id := (SELECT seq_claim_id.NEXTVAL);

  v_claim_number := 'CLM-' || TO_VARCHAR(CURRENT_TIMESTAMP(), 'YYYY') || '-' ||
                    LPAD(TO_VARCHAR(:v_claim_id), 10, '0');

  -- Snowflake UNIQUE constraints are not enforced; guard explicitly
  -- (replaces Oracle's DUP_VAL_ON_INDEX handler).
  IF (EXISTS (SELECT 1 FROM claim WHERE claim_number = :v_claim_number)) THEN
    RAISE duplicate_claim;
  END IF;

  INSERT INTO claim (
    claim_id, claim_number, policy_id, loss_date, reported_date,
    claim_type, status, reserve_amount, paid_amount, description
  ) VALUES (
    :v_claim_id, :v_claim_number, :p_policy_id, :p_loss_date, CURRENT_TIMESTAMP(),
    :p_claim_type, 'OPEN', fn_default_reserve(), 0, :p_description
  );

  RETURN v_claim_id;
END;
$$;

--------------------------------------------------------------------------------
-- claims_pkg.post_payment -> procedure.
-- RETURNING ... INTO is not supported: re-query the claim after the UPDATE.
--------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE post_payment(
  p_claim_id NUMBER,
  p_amount   NUMBER,
  p_method   VARCHAR,
  p_check_no VARCHAR
)
  RETURNS VARCHAR
  LANGUAGE SQL
AS
$$
DECLARE
  v_reserve NUMBER(14,2);
  v_paid    NUMBER(14,2);
BEGIN
  INSERT INTO claim_payment (
    payment_id, claim_id, payment_date, amount, payment_method, check_number
  ) VALUES (
    seq_payment_id.NEXTVAL, :p_claim_id, CURRENT_TIMESTAMP(), :p_amount, :p_method, :p_check_no
  );

  UPDATE claim
     SET paid_amount = paid_amount + :p_amount
   WHERE claim_id = :p_claim_id;

  -- Re-query in place of Oracle's RETURNING reserve_amount, paid_amount INTO.
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

  -- No explicit COMMIT: the caller / session autocommit owns the transaction.
  RETURN 'OK';
END;
$$;

--------------------------------------------------------------------------------
-- claims_pkg.loss_ratio -> scalar SQL UDF (total paid / annual premium).
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION loss_ratio(p_policy_id NUMBER)
  RETURNS NUMBER(14,4)
AS
$$
  SELECT ROUND(
           COALESCE((SELECT SUM(c.paid_amount)
                       FROM claim c
                      WHERE c.policy_id = p_policy_id), 0)
           / NULLIF((SELECT p.annual_premium
                       FROM policy p
                      WHERE p.policy_id = p_policy_id), 0),
           4)
$$;

--------------------------------------------------------------------------------
-- fn_customer_full_name -> scalar SQL UDF (returns NULL when not found,
-- matching the Oracle NO_DATA_FOUND handler).
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_customer_full_name(p_customer_id NUMBER)
  RETURNS VARCHAR
AS
$$
  SELECT last_name || ', ' || first_name
    FROM customer
   WHERE customer_id = p_customer_id
$$;
