--------------------------------------------------------------------------------
-- The Hartford - Claims Data Store
-- claims_pkg (db/oracle/02_packages.sql) re-implemented as standalone Snowflake
-- objects. Snowflake has no packages, so each program unit becomes its own
-- procedure/function, prefixed claims_ to keep the grouping visible.
--
--   claims_pkg.g_default_reserve -> claims_default_reserve()   (scalar SQL UDF)
--   claims_pkg.open_claim        -> claims_open_claim(...)     (Scripting procedure)
--   claims_pkg.post_payment      -> claims_post_payment(...)   (Scripting procedure)
--   claims_pkg.loss_ratio        -> claims_loss_ratio(...)     (scalar SQL UDF)
--   fn_customer_full_name        -> fn_customer_full_name(...) (scalar SQL UDF)
--   trg_customer_biu / trg_policy_bi -> column defaults in 01_schema.sql
--
-- Other differences from PL/SQL:
--   * RAISE_APPLICATION_ERROR -> declared EXCEPTION (-20xxx) + RAISE.
--   * RETURNING ... INTO is not supported -> re-query after the UPDATE.
--   * Snowflake does not enforce UNIQUE/FK/CHECK, so the checks Oracle got from
--     constraints (DUP_VAL_ON_INDEX, FK on claim_id) are done explicitly.
--   * Procedures return a single value; callers use CALL (see ClaimDao).
--------------------------------------------------------------------------------

USE SCHEMA HARTFORD.CLAIMS;

--------------------------------------------------------------------------------
-- Former package constant g_default_reserve.
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION claims_default_reserve()
  RETURNS NUMBER(14,2)
  AS
$$
  2500
$$;

--------------------------------------------------------------------------------
-- claims_open_claim: book a new claim and return the generated claim_id.
--------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE claims_open_claim(
    p_policy_id   NUMBER(12,0),
    p_loss_date   TIMESTAMP_NTZ,
    p_claim_type  VARCHAR,
    p_description VARCHAR
)
RETURNS NUMBER(12,0)
LANGUAGE SQL
AS
$$
DECLARE
  v_claim_id     NUMBER(12,0);
  v_claim_number VARCHAR(24);
  v_existing     INTEGER;
  duplicate_claim_number EXCEPTION (-20001, 'Duplicate claim number generated');
BEGIN
  SELECT seq_claim_id.NEXTVAL INTO :v_claim_id;

  v_claim_number := 'CLM-' || TO_VARCHAR(CURRENT_TIMESTAMP(), 'YYYY') || '-' ||
                    LPAD(TO_VARCHAR(v_claim_id), 10, '0');

  -- Oracle relied on uq_claim_number (DUP_VAL_ON_INDEX); Snowflake does not
  -- enforce UNIQUE, so check explicitly.
  SELECT COUNT(*) INTO :v_existing FROM claim WHERE claim_number = :v_claim_number;
  IF (v_existing > 0) THEN
    RAISE duplicate_claim_number;
  END IF;

  INSERT INTO claim (
    claim_id, claim_number, policy_id, loss_date, reported_date,
    claim_type, status, reserve_amount, paid_amount, description
  ) VALUES (
    :v_claim_id, :v_claim_number, :p_policy_id, :p_loss_date, CURRENT_TIMESTAMP(),
    :p_claim_type, 'OPEN', claims_default_reserve(), 0, :p_description
  );

  RETURN v_claim_id;
END;
$$;

--------------------------------------------------------------------------------
-- claims_post_payment: post a payment against a claim, add it to paid_amount,
-- and close the claim once payments meet/exceed the reserve. Returns the
-- resulting claim status.
--------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE claims_post_payment(
    p_claim_id  NUMBER(12,0),
    p_amount    NUMBER(14,2),
    p_method    VARCHAR,
    p_check_no  VARCHAR DEFAULT NULL
)
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
DECLARE
  v_reserve NUMBER(14,2);
  v_paid    NUMBER(14,2);
  v_status  VARCHAR(16);
  claim_not_found EXCEPTION (-20002, 'Claim not found');
BEGIN
  BEGIN TRANSACTION;

  UPDATE claim
     SET paid_amount = paid_amount + :p_amount
   WHERE claim_id = :p_claim_id;

  -- Oracle's fk_payment_claim rejected payments for unknown claims; Snowflake
  -- does not enforce FKs, so check the UPDATE hit a row.
  IF (SQLROWCOUNT = 0) THEN
    RAISE claim_not_found;
  END IF;

  INSERT INTO claim_payment (claim_id, payment_date, amount, payment_method, check_number)
  VALUES (:p_claim_id, CURRENT_TIMESTAMP(), :p_amount, :p_method, :p_check_no);

  -- RETURNING ... INTO is not supported: re-query the updated row.
  SELECT reserve_amount, paid_amount, status
    INTO :v_reserve, :v_paid, :v_status
    FROM claim
   WHERE claim_id = :p_claim_id;

  IF (v_paid >= v_reserve) THEN
    UPDATE claim
       SET status = 'CLOSED'
     WHERE claim_id = :p_claim_id;
    v_status := 'CLOSED';
  END IF;

  COMMIT;
  RETURN v_status;
EXCEPTION
  WHEN OTHER THEN
    ROLLBACK;
    RAISE;
END;
$$;

--------------------------------------------------------------------------------
-- claims_loss_ratio: total paid / annual premium for a policy, rounded to 4dp;
-- 0 when the premium is 0. Returns NULL for an unknown policy (Oracle raised
-- NO_DATA_FOUND; ClaimDao.lossRatio turns NULL into an exception).
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION claims_loss_ratio(p_policy_id NUMBER(12,0))
  RETURNS NUMBER(18,4)
  AS
$$
  SELECT CASE
           WHEN COUNT(p.policy_id) = 0 THEN NULL
           WHEN COALESCE(MAX(p.annual_premium), 0) = 0 THEN 0
           ELSE ROUND(COALESCE(SUM(c.paid_amount), 0) / MAX(p.annual_premium), 4)
         END
    FROM policy p
    LEFT JOIN claim c
      ON c.policy_id = p.policy_id
   WHERE p.policy_id = p_policy_id
$$;

--------------------------------------------------------------------------------
-- fn_customer_full_name: "Last, First" or NULL when the customer is unknown.
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_customer_full_name(p_customer_id NUMBER(12,0))
  RETURNS VARCHAR(200)
  AS
$$
  SELECT MAX(last_name || ', ' || first_name)
    FROM customer
   WHERE customer_id = p_customer_id
$$;
