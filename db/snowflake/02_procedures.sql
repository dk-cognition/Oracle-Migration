--------------------------------------------------------------------------------
-- The Hartford - Claims Data Store
-- Snowflake Scripting procedures/functions, migrated from db/oracle/02_packages.sql.
--
-- Migration notes:
--   * Snowflake has no packages: claims_pkg is split into standalone objects.
--   * seq.NEXTVAL FROM dual -> seq.NEXTVAL (no DUAL).
--   * RAISE_APPLICATION_ERROR -> declared EXCEPTION + RAISE.
--   * RETURNING ... INTO is unsupported -> follow-up re-query.
--   * g_default_reserve package constant -> scalar UDF fn_default_reserve().
--   * BEFORE INSERT triggers -> column defaults (see 01_schema.sql);
--     "on update" timestamp maintenance -> Stream + Task (04_streams_tasks.sql).
--------------------------------------------------------------------------------

USE SCHEMA hartford.claims;

--------------------------------------------------------------------------------
-- Package constant replacement.
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_default_reserve()
  RETURNS NUMBER(14,2)
  AS $$ 2500 $$;

--------------------------------------------------------------------------------
-- Standalone function: fn_customer_full_name
-- (SQL UDF; returns NULL when the customer does not exist, like NO_DATA_FOUND.)
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_customer_full_name(p_customer_id NUMBER)
  RETURNS VARCHAR
  AS
  $$
    SELECT last_name || ', ' || first_name
      FROM customer
     WHERE customer_id = p_customer_id
  $$;

--------------------------------------------------------------------------------
-- open_claim: books a new claim and returns the generated claim_id.
--------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE open_claim(
    p_policy_id  NUMBER,
    p_loss_date  TIMESTAMP_NTZ,
    p_claim_type VARCHAR,
    p_description VARCHAR)
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
-- post_payment: records a payment and auto-closes a fully paid claim.
--------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE post_payment(
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
BEGIN
  INSERT INTO claim_payment (
    payment_id, claim_id, payment_date, amount, payment_method, check_number
  ) VALUES (
    seq_payment_id.NEXTVAL, :p_claim_id, CURRENT_TIMESTAMP(), :p_amount, :p_method, :p_check_no
  );

  UPDATE claim
     SET paid_amount = paid_amount + :p_amount
   WHERE claim_id = :p_claim_id;

  -- Snowflake has no RETURNING ... INTO; re-query the updated row instead.
  SELECT reserve_amount, paid_amount
    INTO :v_reserve, :v_paid
    FROM claim
   WHERE claim_id = :p_claim_id;

  IF (:v_paid >= :v_reserve) THEN
    UPDATE claim
       SET status = 'CLOSED'
     WHERE claim_id = :p_claim_id;
    RETURN 'CLOSED';
  END IF;

  RETURN 'OPEN';
END;
$$;

--------------------------------------------------------------------------------
-- loss_ratio: total paid / annual premium for a policy.
--------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE loss_ratio(p_policy_id NUMBER)
  RETURNS NUMBER(14,4)
  LANGUAGE SQL
AS
$$
DECLARE
  v_paid    NUMBER(14,2);
  v_premium NUMBER(14,2);
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
