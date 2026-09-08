--------------------------------------------------------------------------------
-- The Hartford - Claims Data Store
-- claims_pkg re-implemented as Snowflake Scripting procedures + SQL UDFs,
-- translated from db/oracle/02_packages.sql.
--
-- Snowflake has no packages, so each program unit is its own object:
--   claims_pkg.g_default_reserve -> default_reserve()          (scalar SQL UDF)
--   claims_pkg.open_claim        -> open_claim(...)            (procedure, RETURNS NUMBER)
--   claims_pkg.post_payment      -> post_payment(...)          (procedure)
--   claims_pkg.loss_ratio        -> loss_ratio(policy_id)      (scalar SQL UDF)
--   fn_customer_full_name        -> fn_customer_full_name(id)  (scalar SQL UDF)
--   trg_customer_biu/trg_policy_bi -> column DEFAULTs (01_schema.sql) +
--                                     Streams/Tasks (04_streams_tasks.sql)
--
-- Called from Java as:  CALL open_claim(?, ?, ?, ?)   /  SELECT loss_ratio(?)
--------------------------------------------------------------------------------

USE SCHEMA hartford.claims;

--------------------------------------------------------------------------------
-- Package constant g_default_reserve
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION default_reserve()
  RETURNS NUMBER(14,2)
  IMMUTABLE
AS
$$
  2500
$$;

--------------------------------------------------------------------------------
-- open_claim: book a new claim and return the generated claim_id.
--------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE open_claim (
  p_policy_id    NUMBER,
  p_loss_date    TIMESTAMP_NTZ,
  p_claim_type   VARCHAR,
  p_description  VARCHAR
)
  RETURNS NUMBER
  LANGUAGE SQL
  EXECUTE AS CALLER
AS
$$
DECLARE
  v_claim_id      NUMBER(12,0);
  v_claim_number  VARCHAR(24);
  v_dupes         NUMBER;
  dup_claim_number EXCEPTION (-20001, 'Duplicate claim number generated');
BEGIN
  -- Sequence without DUAL.
  SELECT seq_claim_id.NEXTVAL INTO :v_claim_id;

  v_claim_number := 'CLM-' || TO_VARCHAR(CURRENT_TIMESTAMP(), 'YYYY') || '-' ||
                    LPAD(TO_VARCHAR(:v_claim_id), 10, '0');

  -- Snowflake does not enforce UNIQUE constraints, so DUP_VAL_ON_INDEX is
  -- replaced by an explicit existence check.
  SELECT COUNT(*) INTO :v_dupes
    FROM claim
   WHERE claim_number = :v_claim_number;
  IF (v_dupes > 0) THEN
    RAISE dup_claim_number;
  END IF;

  INSERT INTO claim (
    claim_id, claim_number, policy_id, loss_date, reported_date,
    claim_type, status, reserve_amount, paid_amount, description
  ) VALUES (
    :v_claim_id, :v_claim_number, :p_policy_id, :p_loss_date, CURRENT_TIMESTAMP(),
    :p_claim_type, 'OPEN', default_reserve(), 0, :p_description
  );

  RETURN v_claim_id;
END;
$$;

--------------------------------------------------------------------------------
-- post_payment: post a payment; update paid_amount; auto-close when fully paid.
-- RETURNING ... INTO is not supported -> re-query after the UPDATE.
--------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE post_payment (
  p_claim_id   NUMBER,
  p_amount     NUMBER(14,2),
  p_method     VARCHAR,
  p_check_no   VARCHAR DEFAULT NULL
)
  RETURNS VARCHAR
  LANGUAGE SQL
  EXECUTE AS CALLER
AS
$$
DECLARE
  v_reserve NUMBER(14,2);
  v_paid    NUMBER(14,2);
  v_status  VARCHAR(16);
BEGIN
  BEGIN TRANSACTION;

  INSERT INTO claim_payment (
    payment_id, claim_id, payment_date, amount, payment_method, check_number
  ) VALUES (
    seq_payment_id.NEXTVAL, :p_claim_id, CURRENT_TIMESTAMP(), :p_amount, :p_method, :p_check_no
  );

  UPDATE claim
     SET paid_amount = paid_amount + :p_amount
   WHERE claim_id = :p_claim_id;

  SELECT reserve_amount, paid_amount, status
    INTO :v_reserve, :v_paid, :v_status
    FROM claim
   WHERE claim_id = :p_claim_id;

  -- Auto-close when payments meet/exceed the reserve.
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
-- loss_ratio: total paid / annual premium for a policy (0 when premium is 0).
-- Pure read -> scalar SQL UDF so it can be used inline in queries.
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION loss_ratio (p_policy_id NUMBER)
  RETURNS NUMBER(14,4)
AS
$$
  SELECT IFF(COALESCE(p.annual_premium, 0) = 0,
             0,
             ROUND(COALESCE(SUM(c.paid_amount), 0) / p.annual_premium, 4))
    FROM policy p
    LEFT JOIN claim c
      ON c.policy_id = p.policy_id
   WHERE p.policy_id = p_policy_id
   GROUP BY p.annual_premium
$$;

--------------------------------------------------------------------------------
-- fn_customer_full_name: "Last, First" (NULL when the customer does not exist,
-- matching the Oracle NO_DATA_FOUND handler).
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_customer_full_name (p_customer_id NUMBER)
  RETURNS VARCHAR(200)
AS
$$
  SELECT last_name || ', ' || first_name
    FROM customer
   WHERE customer_id = p_customer_id
$$;
