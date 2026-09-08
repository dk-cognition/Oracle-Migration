--------------------------------------------------------------------------------
-- The Hartford - Claims Data Store
-- Oracle trigger logic re-expressed as Snowflake Streams + Tasks.
--
--   trg_customer_biu  PK default + created_ts  -> column DEFAULTs (01_schema.sql)
--                     updated_ts on UPDATE     -> st_customer_changes + tk_customer_updated_ts
--   trg_policy_bi     policy_id from sequence  -> column DEFAULT (01_schema.sql)
--   claims_pkg.post_payment auto-close         -> st_claim_payment_new + tk_apply_payments
--                     (covers payments that arrive via COPY INTO / Snowpipe and
--                      therefore bypass the post_payment procedure)
--   mv_daily_paid REFRESH FAST ON COMMIT       -> Snowflake MV auto-maintenance (03_views.sql)
--
-- Tasks are created SUSPENDED; the final ALTER ... RESUME statements start them.
--------------------------------------------------------------------------------

USE SCHEMA hartford.claims;

--------------------------------------------------------------------------------
-- customer.updated_ts maintenance.
-- The stream exposes both images of an UPDATE (DELETE = before, INSERT = after).
-- Only rows whose writer did NOT touch updated_ts are bumped, so the task's own
-- UPDATE (which changes updated_ts) never re-triggers itself.
--------------------------------------------------------------------------------
CREATE OR REPLACE STREAM st_customer_changes
  ON TABLE customer
  APPEND_ONLY = FALSE
  SHOW_INITIAL_ROWS = FALSE;

CREATE OR REPLACE TASK tk_customer_updated_ts
  WAREHOUSE = CLAIMS_WH
  SCHEDULE  = '1 MINUTE'
  WHEN SYSTEM$STREAM_HAS_DATA('st_customer_changes')
AS
  MERGE INTO customer tgt
  USING (
    SELECT new_img.customer_id
      FROM st_customer_changes new_img
      JOIN st_customer_changes old_img
        ON  old_img.METADATA$ROW_ID = new_img.METADATA$ROW_ID
        AND old_img.METADATA$ACTION = 'DELETE'
        AND old_img.METADATA$ISUPDATE
     WHERE new_img.METADATA$ACTION = 'INSERT'
       AND new_img.METADATA$ISUPDATE
       AND new_img.updated_ts = old_img.updated_ts
  ) src
     ON tgt.customer_id = src.customer_id
  WHEN MATCHED THEN UPDATE SET tgt.updated_ts = CURRENT_TIMESTAMP();

--------------------------------------------------------------------------------
-- Apply Snowpipe-landed payments (claim_payment_landing, see 05_stage_pipe.sql)
-- to claim_payment + claim, mirroring post_payment(): insert the payment row,
-- add to paid_amount, auto-close when paid >= reserve. App-originated payments
-- go through post_payment() directly and never touch the landing table, so
-- nothing is applied twice.
--------------------------------------------------------------------------------
CREATE OR REPLACE STREAM st_claim_payment_landing
  ON TABLE claim_payment_landing
  APPEND_ONLY = TRUE
  SHOW_INITIAL_ROWS = FALSE;

CREATE OR REPLACE TASK tk_apply_landed_payments
  WAREHOUSE = CLAIMS_WH
  SCHEDULE  = '5 MINUTE'
  WHEN SYSTEM$STREAM_HAS_DATA('st_claim_payment_landing')
AS
BEGIN
  CREATE OR REPLACE TEMPORARY TABLE tmp_landed AS
    SELECT claim_id, payment_date, amount, payment_method, check_number
      FROM st_claim_payment_landing
     WHERE METADATA$ACTION = 'INSERT';

  INSERT INTO claim_payment (claim_id, payment_date, amount, payment_method, check_number)
    SELECT claim_id, COALESCE(payment_date, CURRENT_TIMESTAMP()), amount, payment_method, check_number
      FROM tmp_landed;

  MERGE INTO claim tgt
  USING (
    SELECT claim_id, SUM(amount) AS new_paid
      FROM tmp_landed
     GROUP BY claim_id
  ) src
     ON tgt.claim_id = src.claim_id
  WHEN MATCHED THEN UPDATE
    SET tgt.paid_amount = tgt.paid_amount + src.new_paid,
        tgt.status      = IFF(tgt.paid_amount + src.new_paid >= tgt.reserve_amount,
                              'CLOSED', tgt.status);
END;

--------------------------------------------------------------------------------
-- Start the tasks.
--------------------------------------------------------------------------------
ALTER TASK tk_customer_updated_ts RESUME;
ALTER TASK tk_apply_landed_payments RESUME;
