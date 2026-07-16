--------------------------------------------------------------------------------
-- The Hartford - Claims Data Store
-- PL/SQL packages, procedures, functions, and triggers.
--
-- NOTE (migration): PL/SQL packages do not exist in Snowflake. These must be
-- re-implemented as Snowflake Scripting procedures, SQL UDFs, Streams+Tasks
-- (for triggers), or pushed into the application/dbt layer. See docs/MIGRATION.md.
--------------------------------------------------------------------------------

ALTER SESSION SET CURRENT_SCHEMA = HARTFORD;

--------------------------------------------------------------------------------
-- Package spec: claims_pkg
--------------------------------------------------------------------------------
CREATE OR REPLACE PACKAGE hartford.claims_pkg AS

  -- Book a new claim and return the generated claim_id.
  FUNCTION open_claim (
    p_policy_id   IN NUMBER,
    p_loss_date   IN DATE,
    p_claim_type  IN VARCHAR2,
    p_description  IN VARCHAR2
  ) RETURN NUMBER;

  -- Post a payment against a claim; updates paid_amount and closes if fully paid.
  PROCEDURE post_payment (
    p_claim_id   IN NUMBER,
    p_amount     IN NUMBER,
    p_method     IN VARCHAR2,
    p_check_no   IN VARCHAR2 DEFAULT NULL
  );

  -- Loss ratio for a policy = total paid / annual premium.
  FUNCTION loss_ratio (p_policy_id IN NUMBER) RETURN NUMBER;

  g_default_reserve CONSTANT NUMBER := 2500;

END claims_pkg;
/

--------------------------------------------------------------------------------
-- Package body: claims_pkg
--------------------------------------------------------------------------------
CREATE OR REPLACE PACKAGE BODY hartford.claims_pkg AS

  FUNCTION open_claim (
    p_policy_id   IN NUMBER,
    p_loss_date   IN DATE,
    p_claim_type  IN VARCHAR2,
    p_description  IN VARCHAR2
  ) RETURN NUMBER
  IS
    v_claim_id     NUMBER;
    v_claim_number VARCHAR2(24);
  BEGIN
    -- Sequence + DUAL: both are Oracle-specific patterns.
    SELECT hartford.seq_claim_id.NEXTVAL INTO v_claim_id FROM dual;

    v_claim_number := 'CLM-' || TO_CHAR(SYSDATE, 'YYYY') || '-' ||
                      LPAD(TO_CHAR(v_claim_id), 10, '0');

    INSERT INTO hartford.claim (
      claim_id, claim_number, policy_id, loss_date, reported_date,
      claim_type, status, reserve_amount, paid_amount, description
    ) VALUES (
      v_claim_id, v_claim_number, p_policy_id, p_loss_date, SYSDATE,
      p_claim_type, 'OPEN', g_default_reserve, 0, p_description
    );

    RETURN v_claim_id;
  EXCEPTION
    WHEN DUP_VAL_ON_INDEX THEN
      RAISE_APPLICATION_ERROR(-20001, 'Duplicate claim number generated: ' || v_claim_number);
  END open_claim;

  PROCEDURE post_payment (
    p_claim_id   IN NUMBER,
    p_amount     IN NUMBER,
    p_method     IN VARCHAR2,
    p_check_no   IN VARCHAR2 DEFAULT NULL
  )
  IS
    v_reserve NUMBER;
    v_paid    NUMBER;
  BEGIN
    INSERT INTO hartford.claim_payment (
      payment_id, claim_id, payment_date, amount, payment_method, check_number
    ) VALUES (
      hartford.seq_payment_id.NEXTVAL, p_claim_id, SYSDATE, p_amount, p_method, p_check_no
    );

    UPDATE hartford.claim
       SET paid_amount = paid_amount + p_amount
     WHERE claim_id = p_claim_id
     RETURNING reserve_amount, paid_amount INTO v_reserve, v_paid;

    -- Auto-close when payments meet/exceed the reserve.
    IF v_paid >= v_reserve THEN
      UPDATE hartford.claim
         SET status = 'CLOSED'
       WHERE claim_id = p_claim_id;
    END IF;

    COMMIT;
  END post_payment;

  FUNCTION loss_ratio (p_policy_id IN NUMBER) RETURN NUMBER
  IS
    v_paid    NUMBER;
    v_premium NUMBER;
  BEGIN
    SELECT NVL(SUM(c.paid_amount), 0)
      INTO v_paid
      FROM hartford.claim c
     WHERE c.policy_id = p_policy_id;

    SELECT annual_premium INTO v_premium
      FROM hartford.policy
     WHERE policy_id = p_policy_id;

    -- DECODE + NVL: classic Oracle. Guard divide-by-zero.
    RETURN DECODE(NVL(v_premium, 0), 0, 0, ROUND(v_paid / v_premium, 4));
  END loss_ratio;

END claims_pkg;
/

--------------------------------------------------------------------------------
-- Standalone function: fn_customer_full_name
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION hartford.fn_customer_full_name (p_customer_id IN NUMBER)
  RETURN VARCHAR2
IS
  v_name VARCHAR2(200);
BEGIN
  SELECT last_name || ', ' || first_name
    INTO v_name
    FROM hartford.customer
   WHERE customer_id = p_customer_id;
  RETURN v_name;
EXCEPTION
  WHEN NO_DATA_FOUND THEN
    RETURN NULL;
END fn_customer_full_name;
/

--------------------------------------------------------------------------------
-- Trigger: maintain updated_ts + populate PK from sequence on insert.
-- (Snowflake has no row-level triggers; use IDENTITY defaults + Streams/Tasks.)
--------------------------------------------------------------------------------
CREATE OR REPLACE TRIGGER hartford.trg_customer_biu
  BEFORE INSERT OR UPDATE ON hartford.customer
  FOR EACH ROW
BEGIN
  IF INSERTING THEN
    IF :NEW.customer_id IS NULL THEN
      :NEW.customer_id := hartford.seq_customer_id.NEXTVAL;
    END IF;
    :NEW.created_ts := SYSDATE;
  END IF;
  :NEW.updated_ts := SYSDATE;
END;
/

CREATE OR REPLACE TRIGGER hartford.trg_policy_bi
  BEFORE INSERT ON hartford.policy
  FOR EACH ROW
WHEN (NEW.policy_id IS NULL)
BEGIN
  :NEW.policy_id := hartford.seq_policy_id.NEXTVAL;
END;
/
