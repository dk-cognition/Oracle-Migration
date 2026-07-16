--------------------------------------------------------------------------------
-- The Hartford - Claims Data Store
-- claims_pkg re-implemented for Snowflake -- migrated from db/oracle/02_packages.sql.
--
-- Snowflake has no PL/SQL packages, package constants, or row-level triggers.
-- Migration notes (see docs/MIGRATION.md):
--   * Each package program unit becomes its own CREATE PROCEDURE / FUNCTION.
--   * Package constant g_default_reserve -> scalar UDF fn_default_reserve().
--   * RAISE_APPLICATION_ERROR -> a Scripting declared EXCEPTION + RAISE.
--   * RETURNING ... INTO is unsupported -> re-query for the values.
--   * Transaction boundaries: Snowflake procedures run with AUTOCOMMIT on, so
--     each DML auto-commits; the Oracle explicit COMMIT is dropped. Wrap the
--     body in BEGIN TRANSACTION ... COMMIT if all-or-nothing semantics matter.
--   * The trg_customer_biu / trg_policy_bi triggers are replaced by
--     AUTOINCREMENT + DEFAULT CURRENT_TIMESTAMP columns in 01_schema.sql.
--------------------------------------------------------------------------------

USE SCHEMA HARTFORD.CLAIMS;

--------------------------------------------------------------------------------
-- Package constant g_default_reserve (2500) -> scalar UDF.
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_default_reserve()
  RETURNS NUMBER
  AS $$ 2500 $$;

--------------------------------------------------------------------------------
-- claims_pkg.open_claim -> standalone procedure. Books a new claim and returns
-- the generated claim_id.
--------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE open_claim (
    p_policy_id  NUMBER,
    p_loss_date  TIMESTAMP_NTZ,
    p_claim_type VARCHAR,
    p_description VARCHAR
)
  RETURNS NUMBER
  LANGUAGE SQL
AS
$$
DECLARE
  duplicate_claim EXCEPTION (-20001, 'Duplicate claim number generated');
  v_claim_id     NUMBER;
  v_claim_number VARCHAR;
BEGIN
  -- Oracle: SELECT seq_claim_id.NEXTVAL FROM dual (no DUAL in Snowflake).
  v_claim_id := (SELECT seq_claim_id.NEXTVAL);

  v_claim_number := 'CLM-' || TO_VARCHAR(CURRENT_TIMESTAMP(), 'YYYY') || '-' ||
                    LPAD(TO_VARCHAR(v_claim_id), 10, '0');

  INSERT INTO claim (
    claim_id, claim_number, policy_id, loss_date, reported_date,
    claim_type, status, reserve_amount, paid_amount, description
  ) VALUES (
    :v_claim_id, :v_claim_number, :p_policy_id, :p_loss_date, CURRENT_TIMESTAMP(),
    :p_claim_type, 'OPEN', fn_default_reserve(), 0, :p_description
  );

  RETURN v_claim_id;
EXCEPTION
  -- Oracle raised RAISE_APPLICATION_ERROR(-20001, ...) on DUP_VAL_ON_INDEX.
  WHEN OTHER THEN
    RAISE duplicate_claim;
END;
$$;

--------------------------------------------------------------------------------
-- claims_pkg.post_payment -> standalone procedure. Posts a payment and closes
-- the claim once payments meet/exceed the reserve.
--------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE post_payment (
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
  v_reserve NUMBER;
  v_paid    NUMBER;
BEGIN
  -- payment_id is AUTOINCREMENT (was seq_payment_id.NEXTVAL); omit it.
  INSERT INTO claim_payment (
    claim_id, payment_date, amount, payment_method, check_number
  ) VALUES (
    :p_claim_id, CURRENT_TIMESTAMP(), :p_amount, :p_method, :p_check_no
  );

  UPDATE claim
     SET paid_amount = paid_amount + :p_amount
   WHERE claim_id = :p_claim_id;

  -- Oracle used RETURNING reserve_amount, paid_amount INTO ...; re-query instead.
  SELECT reserve_amount, paid_amount
    INTO :v_reserve, :v_paid
    FROM claim
   WHERE claim_id = :p_claim_id;

  IF (v_paid >= v_reserve) THEN
    UPDATE claim
       SET status = 'CLOSED'
     WHERE claim_id = :p_claim_id;
  END IF;

  RETURN 'OK';
END;
$$;

--------------------------------------------------------------------------------
-- claims_pkg.loss_ratio -> scalar UDF. total paid / annual premium.
-- DECODE + NVL -> CASE + COALESCE (guards divide-by-zero).
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION loss_ratio (p_policy_id NUMBER)
  RETURNS NUMBER
  LANGUAGE SQL
AS
$$
  SELECT CASE
           WHEN COALESCE(p.annual_premium, 0) = 0 THEN 0
           ELSE ROUND(
                  COALESCE(
                    (SELECT SUM(c.paid_amount)
                       FROM claim c
                      WHERE c.policy_id = p_policy_id), 0)
                  / p.annual_premium, 4)
         END
    FROM policy p
   WHERE p.policy_id = p_policy_id
$$;

--------------------------------------------------------------------------------
-- Standalone function: fn_customer_full_name.
-- Oracle NO_DATA_FOUND -> NULL is the natural result of the scalar subquery.
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_customer_full_name (p_customer_id NUMBER)
  RETURNS VARCHAR
  LANGUAGE SQL
AS
$$
  SELECT last_name || ', ' || first_name
    FROM customer
   WHERE customer_id = p_customer_id
$$;
