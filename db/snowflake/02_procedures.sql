--------------------------------------------------------------------------------
-- The Hartford - Claims Data Store
-- Snowflake Scripting procedures and SQL UDFs.
--
-- PL/SQL package units are standalone Snowflake procedures/UDFs because
-- Snowflake has no package construct.
--------------------------------------------------------------------------------

USE SCHEMA hartford;

CREATE OR REPLACE FUNCTION hartford.fn_default_reserve()
  RETURNS NUMBER
  LANGUAGE SQL
  AS
  $$ 2500 $$;

CREATE OR REPLACE PROCEDURE hartford.open_claim(
    p_policy_id NUMBER,
    p_loss_date TIMESTAMP_NTZ,
    p_claim_type VARCHAR,
    p_description VARCHAR
  )
  RETURNS NUMBER
  LANGUAGE SQL
  EXECUTE AS OWNER
  AS
  $$
  DECLARE
    v_claim_id NUMBER;
    v_claim_number VARCHAR;
    e_duplicate_claim EXCEPTION (-20001, 'Duplicate claim number generated');
  BEGIN
    SELECT hartford.seq_claim_id.NEXTVAL INTO :v_claim_id;

    v_claim_number := 'CLM-' || TO_VARCHAR(CURRENT_TIMESTAMP(), 'YYYY') || '-' ||
                      LPAD(TO_VARCHAR(v_claim_id), 10, '0');

    INSERT INTO hartford.claim (
      claim_id, claim_number, policy_id, loss_date, reported_date,
      claim_type, status, reserve_amount, paid_amount, description
    ) VALUES (
      :v_claim_id, :v_claim_number, :p_policy_id, :p_loss_date,
      CURRENT_TIMESTAMP(), :p_claim_type, 'OPEN',
      hartford.fn_default_reserve(), 0, :p_description
    );

    RETURN v_claim_id;
  EXCEPTION
    WHEN STATEMENT_ERROR THEN
      IF (SQLERRM ILIKE '%duplicate%' OR SQLERRM ILIKE '%unique%') THEN
        RAISE e_duplicate_claim;
      ELSE
        RAISE;
      END IF;
  END;
  $$;

CREATE OR REPLACE PROCEDURE hartford.post_payment(
    p_claim_id NUMBER,
    p_amount NUMBER,
    p_method VARCHAR,
    p_check_no VARCHAR
  )
  RETURNS VARCHAR
  LANGUAGE SQL
  EXECUTE AS OWNER
  AS
  $$
  DECLARE
    v_reserve NUMBER;
    v_paid NUMBER;
  BEGIN
    INSERT INTO hartford.claim_payment (
      claim_id, payment_date, amount, payment_method, check_number
    ) VALUES (
      :p_claim_id, CURRENT_TIMESTAMP(), :p_amount, :p_method, :p_check_no
    );

    UPDATE hartford.claim
       SET paid_amount = paid_amount + :p_amount
     WHERE claim_id = :p_claim_id;

    -- Snowflake procedures are autocommit-by-statement; no explicit COMMIT.
    -- There are no procedure default arguments, so callers pass NULL for
    -- p_check_no when a check number is not available.
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

CREATE OR REPLACE FUNCTION hartford.loss_ratio(p_policy_id NUMBER)
  RETURNS NUMBER
  LANGUAGE SQL
  AS
  $$
    SELECT CASE
             WHEN COALESCE(p.annual_premium, 0) = 0 THEN 0
             ELSE ROUND(COALESCE(SUM(cl.paid_amount), 0) / p.annual_premium, 4)
           END
      FROM hartford.policy p
      LEFT JOIN hartford.claim cl ON p.policy_id = cl.policy_id
     WHERE p.policy_id = p_policy_id
     GROUP BY p.annual_premium
  $$;

CREATE OR REPLACE FUNCTION hartford.fn_customer_full_name(p_customer_id NUMBER)
  RETURNS VARCHAR
  LANGUAGE SQL
  AS
  $$
    SELECT last_name || ', ' || first_name
      FROM hartford.customer
     WHERE customer_id = p_customer_id
  $$;
