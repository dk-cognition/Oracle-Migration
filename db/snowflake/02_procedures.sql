--------------------------------------------------------------------------------
-- The Hartford - Claims Data Store
-- Snowflake procedures / functions -- migrated from db/oracle/02_packages.sql
--
-- Snowflake has no PL/SQL packages, package constants, row triggers,
-- RETURNING ... INTO, or DUAL. The Oracle claims_pkg is decomposed into
-- standalone objects (Snowflake Scripting procedures + SQL UDFs):
--
--   claims_pkg.open_claim   -> PROCEDURE hartford.open_claim   (returns claim_id)
--   claims_pkg.post_payment -> PROCEDURE hartford.post_payment
--   claims_pkg.loss_ratio   -> FUNCTION  hartford.loss_ratio   (SQL UDF)
--   claims_pkg.g_default_reserve (constant) -> FUNCTION hartford.fn_default_reserve
--   fn_customer_full_name   -> FUNCTION  hartford.fn_customer_full_name (SQL UDF)
--   trg_customer_biu / trg_policy_bi -> AUTOINCREMENT columns (see 01_schema.sql)
--                                       + Stream+Task (see 04_streams_tasks.sql)
--
-- See docs/MIGRATION.md sections 2-4.
--------------------------------------------------------------------------------

USE SCHEMA hartford.hartford;

--------------------------------------------------------------------------------
-- Package constant g_default_reserve (2500) -> scalar UDF.
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION hartford.fn_default_reserve()
  RETURNS NUMBER(14,2)
  AS
$$
  2500
$$;

--------------------------------------------------------------------------------
-- Standalone function: fn_customer_full_name (SQL UDF).
-- Oracle NO_DATA_FOUND -> NULL is preserved: a scalar subquery with no rows
-- returns NULL.
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION hartford.fn_customer_full_name(p_customer_id NUMBER)
  RETURNS VARCHAR
  AS
$$
  SELECT last_name || ', ' || first_name
    FROM hartford.customer
   WHERE customer_id = p_customer_id
$$;

--------------------------------------------------------------------------------
-- loss_ratio = total paid / annual premium (SQL UDF).
-- Oracle DECODE(NVL(premium,0),0,0,...) -> CASE + COALESCE (divide-by-zero guard).
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION hartford.loss_ratio(p_policy_id NUMBER)
  RETURNS NUMBER(14,4)
  AS
$$
  SELECT CASE
           WHEN COALESCE((SELECT annual_premium
                            FROM hartford.policy
                           WHERE policy_id = p_policy_id), 0) = 0
           THEN 0
           ELSE ROUND(
                  (SELECT COALESCE(SUM(c.paid_amount), 0)
                     FROM hartford.claim c
                    WHERE c.policy_id = p_policy_id)
                  / (SELECT annual_premium
                       FROM hartford.policy
                      WHERE policy_id = p_policy_id), 4)
         END
$$;

--------------------------------------------------------------------------------
-- open_claim: book a new claim and return the generated claim_id.
-- - SELECT seq.NEXTVAL FROM dual -> SELECT seq.NEXTVAL (no DUAL).
-- - g_default_reserve constant -> fn_default_reserve() UDF.
-- - TO_CHAR -> TO_VARCHAR; SYSDATE -> CURRENT_TIMESTAMP().
-- - RAISE_APPLICATION_ERROR -> Scripting EXCEPTION + RAISE. (Note: Snowflake does
--   not enforce UNIQUE, so the duplicate handler is illustrative.)
--------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE hartford.open_claim(
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
  v_claim_number VARCHAR;
  duplicate_claim EXCEPTION (-20001, 'Duplicate claim number generated');
BEGIN
  v_claim_id := (SELECT hartford.seq_claim_id.NEXTVAL);

  v_claim_number := 'CLM-' || TO_VARCHAR(CURRENT_TIMESTAMP(), 'YYYY') || '-' ||
                    LPAD(TO_VARCHAR(:v_claim_id), 10, '0');

  INSERT INTO hartford.claim (
    claim_id, claim_number, policy_id, loss_date, reported_date,
    claim_type, status, reserve_amount, paid_amount, description
  ) VALUES (
    :v_claim_id, :v_claim_number, :p_policy_id, :p_loss_date, CURRENT_TIMESTAMP(),
    :p_claim_type, 'OPEN', hartford.fn_default_reserve(), 0, :p_description
  );

  RETURN :v_claim_id;
EXCEPTION
  WHEN OTHER THEN
    RAISE duplicate_claim;
END;
$$;

--------------------------------------------------------------------------------
-- post_payment: record a payment, bump paid_amount, auto-close when fully paid.
-- - payment_id comes from the AUTOINCREMENT column (no sequence in the INSERT).
-- - RETURNING reserve_amount, paid_amount INTO ... -> re-query after UPDATE.
-- - The Oracle explicit COMMIT is expressed as an explicit transaction so the
--   payment insert, paid_amount update, and auto-close commit atomically.
--------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE hartford.post_payment(
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
  BEGIN TRANSACTION;

  INSERT INTO hartford.claim_payment (
    claim_id, payment_date, amount, payment_method, check_number
  ) VALUES (
    :p_claim_id, CURRENT_TIMESTAMP(), :p_amount, :p_method, :p_check_no
  );

  UPDATE hartford.claim
     SET paid_amount = paid_amount + :p_amount
   WHERE claim_id = :p_claim_id;

  -- No RETURNING ... INTO in Snowflake: re-query the updated row.
  SELECT reserve_amount, paid_amount
    INTO :v_reserve, :v_paid
    FROM hartford.claim
   WHERE claim_id = :p_claim_id;

  IF (:v_paid >= :v_reserve) THEN
    UPDATE hartford.claim
       SET status = 'CLOSED'
     WHERE claim_id = :p_claim_id;
  END IF;

  COMMIT;
  RETURN 'OK';
EXCEPTION
  WHEN OTHER THEN
    ROLLBACK;
    RAISE;
END;
$$;
