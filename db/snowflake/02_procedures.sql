--------------------------------------------------------------------------------
-- The Hartford - Claims Data Store
-- Snowflake procedural layer -- migrated from db/oracle/02_packages.sql
--
-- Migration notes (see docs/MIGRATION.md):
--   * Snowflake has no packages: claims_pkg is split into standalone objects
--     (open_claim, post_payment, loss_ratio) written in Snowflake Scripting.
--   * The package constant g_default_reserve becomes the fn_default_reserve UDF.
--   * fn_customer_full_name becomes a SQL UDF.
--   * There is no DUAL: `SELECT seq.NEXTVAL` (no FROM) is used instead.
--   * RETURNING ... INTO is unsupported: post_payment re-queries the row.
--   * RAISE_APPLICATION_ERROR becomes a declared EXCEPTION + RAISE.
--   * Each procedure runs in its own implicit transaction (autocommit), so the
--     explicit COMMIT is gone; post_payment wraps its multi-statement write in
--     BEGIN TRANSACTION / COMMIT so the payment and claim update land together.
--   * Row-level triggers (trg_customer_biu, trg_policy_bi) have no analog: PK
--     and timestamp defaults live in 01_schema.sql, and the "on update"
--     timestamp is maintained by the Stream+Task in 04_streams_tasks.sql.
--------------------------------------------------------------------------------

USE SCHEMA hartford.claims;

--------------------------------------------------------------------------------
-- Default reserve amount (was the claims_pkg constant g_default_reserve).
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_default_reserve()
  RETURNS NUMBER(14,2)
  LANGUAGE SQL
AS
$$
  2500
$$;

--------------------------------------------------------------------------------
-- open_claim: books a new claim and returns the generated claim_id.
--------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE open_claim(
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
  v_claim_id     NUMBER;
  v_claim_number VARCHAR;
  duplicate_claim_number EXCEPTION (-20001, 'Duplicate claim number generated');
BEGIN
  v_claim_id := (SELECT seq_claim_id.NEXTVAL);

  v_claim_number := 'CLM-' || TO_VARCHAR(CURRENT_TIMESTAMP(), 'YYYY') || '-' ||
                    LPAD(TO_VARCHAR(:v_claim_id), 10, '0');

  -- Snowflake does not enforce UNIQUE constraints, so the duplicate check the
  -- DUP_VAL_ON_INDEX handler relied on has to be explicit.
  IF (EXISTS (SELECT 1 FROM claim WHERE claim_number = :v_claim_number)) THEN
    RAISE duplicate_claim_number;
  END IF;

  INSERT INTO claim (
    claim_id, claim_number, policy_id, loss_date, reported_date,
    claim_type, status, reserve_amount, paid_amount, description
  ) VALUES (
    :v_claim_id, :v_claim_number, :p_policy_id, :p_loss_date, CURRENT_TIMESTAMP(),
    :p_claim_type, 'OPEN', fn_default_reserve(), 0, :p_description
  );

  RETURN :v_claim_id;
END;
$$;

--------------------------------------------------------------------------------
-- post_payment: records a payment and closes the claim once fully paid.
--------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE post_payment(
  p_claim_id NUMBER,
  p_amount   NUMBER(14,2),
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
  unknown_claim EXCEPTION (-20002, 'Claim not found');
BEGIN
  BEGIN TRANSACTION;

  IF (NOT EXISTS (SELECT 1 FROM claim WHERE claim_id = :p_claim_id)) THEN
    RAISE unknown_claim;
  END IF;

  INSERT INTO claim_payment (
    payment_id, claim_id, payment_date, amount, payment_method, check_number
  ) VALUES (
    seq_payment_id.NEXTVAL, :p_claim_id, CURRENT_TIMESTAMP(), :p_amount, :p_method, :p_check_no
  );

  UPDATE claim
     SET paid_amount = paid_amount + :p_amount
   WHERE claim_id = :p_claim_id;

  -- RETURNING ... INTO does not exist in Snowflake: re-read the updated row.
  SELECT reserve_amount, paid_amount
    INTO :v_reserve, :v_paid
    FROM claim
   WHERE claim_id = :p_claim_id;

  IF (:v_paid >= :v_reserve) THEN
    UPDATE claim
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

--------------------------------------------------------------------------------
-- loss_ratio: total paid / annual premium for a policy.
--
-- Kept as a procedure (not a scalar UDF) because it reads two tables; scalar
-- SQL UDFs that query tables cannot be used freely in other queries.
--------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE loss_ratio(p_policy_id NUMBER)
  RETURNS NUMBER(38,4)
  LANGUAGE SQL
AS
$$
DECLARE
  v_paid    NUMBER(14,2);
  v_premium NUMBER(12,2);
BEGIN
  SELECT COALESCE(SUM(c.paid_amount), 0)
    INTO :v_paid
    FROM claim c
   WHERE c.policy_id = :p_policy_id;

  SELECT annual_premium
    INTO :v_premium
    FROM policy
   WHERE policy_id = :p_policy_id;

  IF (COALESCE(:v_premium, 0) = 0) THEN
    RETURN 0;
  END IF;

  RETURN ROUND(:v_paid / :v_premium, 4);
END;
$$;

--------------------------------------------------------------------------------
-- fn_customer_full_name: standalone Oracle function -> SQL UDF.
-- Returns NULL when the customer does not exist (the NO_DATA_FOUND handler).
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_customer_full_name(p_customer_id NUMBER)
  RETURNS VARCHAR
  LANGUAGE SQL
AS
$$
  SELECT last_name || ', ' || first_name
    FROM customer
   WHERE customer_id = p_customer_id
$$;
