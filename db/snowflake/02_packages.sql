--------------------------------------------------------------------------------
-- The Hartford - Claims Data Store
-- Snowflake procedures / functions, migrated from db/oracle/02_packages.sql.
--
-- Migration notes (see docs/MIGRATION.md):
--   * Snowflake has no packages: every claims_pkg program unit becomes its own
--     top-level CREATE PROCEDURE (Snowflake Scripting) or CREATE FUNCTION.
--   * Package constant g_default_reserve -> scalar UDF fn_default_reserve()
--     backed by the app_config table, so the value is changeable without DDL.
--   * RAISE_APPLICATION_ERROR -> a declared EXCEPTION plus RAISE.
--   * UPDATE ... RETURNING ... INTO is unsupported -> re-query after the UPDATE.
--   * SELECT ... FROM dual -> SELECT ... (no DUAL).
--   * Row-level triggers do not exist -> column DEFAULTs (see 01_schema.sql)
--     plus a Stream + Task for the "on update" timestamp.
--------------------------------------------------------------------------------

USE DATABASE hartford;
USE SCHEMA hartford.claims;

--------------------------------------------------------------------------------
-- Config table + scalar UDF replacing the package constant g_default_reserve.
--------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS hartford.claims.app_config (
  config_key   VARCHAR(60)  NOT NULL,
  config_value VARCHAR(200) NOT NULL,
  CONSTRAINT pk_app_config PRIMARY KEY (config_key)
);

MERGE INTO hartford.claims.app_config tgt
USING (SELECT 'default_reserve' AS config_key, '2500' AS config_value) src
   ON tgt.config_key = src.config_key
 WHEN NOT MATCHED THEN
   INSERT (config_key, config_value) VALUES (src.config_key, src.config_value);

CREATE OR REPLACE FUNCTION hartford.claims.fn_default_reserve()
RETURNS NUMBER(14,2)
AS
$$
  SELECT COALESCE(MAX(TO_NUMBER(config_value)), 2500)
    FROM hartford.claims.app_config
   WHERE config_key = 'default_reserve'
$$;

--------------------------------------------------------------------------------
-- claims_pkg.open_claim -> standalone procedure.
-- Books a new claim and returns the generated claim_id.
--------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE hartford.claims.open_claim(
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
  v_existing     NUMBER;
  duplicate_claim_number EXCEPTION (-20001, 'Duplicate claim number generated');
BEGIN
  SELECT hartford.claims.seq_claim_id.NEXTVAL INTO :v_claim_id;

  v_claim_number := 'CLM-' || TO_VARCHAR(CURRENT_TIMESTAMP(), 'YYYY') || '-' ||
                    LPAD(TO_VARCHAR(:v_claim_id), 10, '0');

  -- Snowflake does not enforce the uq_claim_number unique constraint, so the
  -- Oracle DUP_VAL_ON_INDEX path becomes an explicit pre-check.
  SELECT COUNT(*) INTO :v_existing
    FROM hartford.claims.claim
   WHERE claim_number = :v_claim_number;

  IF (v_existing > 0) THEN
    RAISE duplicate_claim_number;
  END IF;

  INSERT INTO hartford.claims.claim (
    claim_id, claim_number, policy_id, loss_date, reported_date,
    claim_type, status, reserve_amount, paid_amount, description
  ) VALUES (
    :v_claim_id, :v_claim_number, :p_policy_id, :p_loss_date, CURRENT_TIMESTAMP(),
    :p_claim_type, 'OPEN', hartford.claims.fn_default_reserve(), 0, :p_description
  );

  RETURN :v_claim_id;
END;
$$;

--------------------------------------------------------------------------------
-- claims_pkg.post_payment -> standalone procedure.
-- Posts a payment, then re-queries the claim (no RETURNING ... INTO) to decide
-- whether the claim is fully paid and should be closed.
--------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE hartford.claims.post_payment(
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
  v_reserve NUMBER;
  v_paid    NUMBER;
BEGIN
  INSERT INTO hartford.claims.claim_payment (
    claim_id, payment_date, amount, payment_method, check_number
  ) VALUES (
    :p_claim_id, CURRENT_TIMESTAMP(), :p_amount, :p_method, :p_check_no
  );

  UPDATE hartford.claims.claim
     SET paid_amount = paid_amount + :p_amount
   WHERE claim_id = :p_claim_id;

  SELECT reserve_amount, paid_amount
    INTO :v_reserve, :v_paid
    FROM hartford.claims.claim
   WHERE claim_id = :p_claim_id;

  IF (v_paid >= v_reserve) THEN
    UPDATE hartford.claims.claim
       SET status = 'CLOSED'
     WHERE claim_id = :p_claim_id;
    RETURN 'CLOSED';
  END IF;

  RETURN 'OPEN';
END;
$$;

--------------------------------------------------------------------------------
-- claims_pkg.loss_ratio -> scalar SQL UDF (total paid / annual premium).
-- DECODE + NVL divide-by-zero guard becomes COALESCE + NULLIF.
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION hartford.claims.loss_ratio(p_policy_id NUMBER)
RETURNS NUMBER(12,4)
AS
$$
  SELECT COALESCE(ROUND(SUM(c.paid_amount) / NULLIF(MAX(p.annual_premium), 0), 4), 0)
    FROM hartford.claims.policy p
    LEFT JOIN hartford.claims.claim c
      ON c.policy_id = p.policy_id
   WHERE p.policy_id = p_policy_id
$$;

--------------------------------------------------------------------------------
-- fn_customer_full_name -> scalar SQL UDF.
-- A missing customer yields no rows, so the UDF returns NULL, matching the
-- Oracle NO_DATA_FOUND handler.
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION hartford.claims.fn_customer_full_name(p_customer_id NUMBER)
RETURNS VARCHAR
AS
$$
  SELECT MAX(last_name || ', ' || first_name)
    FROM hartford.claims.customer
   WHERE customer_id = p_customer_id
$$;

--------------------------------------------------------------------------------
-- trg_customer_biu / trg_policy_bi replacements.
--
-- Key generation and created_ts/reported_date defaults are handled by the
-- IDENTITY / AUTOINCREMENT / DEFAULT clauses in 01_schema.sql. The only piece
-- of trigger behaviour left is refreshing customer.updated_ts on UPDATE, which
-- a Stream + Task performs asynchronously.
--------------------------------------------------------------------------------
CREATE OR REPLACE STREAM hartford.claims.str_customer_changes
  ON TABLE hartford.claims.customer;

CREATE OR REPLACE TASK hartford.claims.tsk_customer_updated_ts
  WAREHOUSE = CLAIMS_WH
  SCHEDULE  = '5 MINUTE'
  WHEN SYSTEM$STREAM_HAS_DATA('hartford.claims.str_customer_changes')
AS
  MERGE INTO hartford.claims.customer tgt
  USING (
    SELECT customer_id, MAX(METADATA$ACTION) AS action
      FROM hartford.claims.str_customer_changes
     WHERE METADATA$ACTION = 'INSERT'
       AND METADATA$ISUPDATE = TRUE
     GROUP BY customer_id
  ) src
     ON tgt.customer_id = src.customer_id
   WHEN MATCHED THEN UPDATE SET tgt.updated_ts = CURRENT_TIMESTAMP();

ALTER TASK hartford.claims.tsk_customer_updated_ts RESUME;
