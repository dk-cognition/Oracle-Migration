--------------------------------------------------------------------------------
-- The Hartford - Claims Data Store
-- Trigger logic re-expressed as Streams + Tasks (docs/MIGRATION.md section 3).
--
-- Snowflake has no row-level triggers. The Oracle triggers map as follows:
--   trg_customer_biu  PK from sequence  -> customer_id DEFAULT seq.NEXTVAL (01_schema.sql)
--                     created_ts        -> DEFAULT CURRENT_TIMESTAMP()     (01_schema.sql)
--                     updated_ts on UPDATE -> strm_customer + task_customer_touch (below)
--   trg_policy_bi     PK from sequence  -> policy_id DEFAULT seq.NEXTVAL   (01_schema.sql)
--   MV fast refresh   -> Snowflake MVs auto-maintain; the claim auto-close side
--                        effect of claims_pkg.post_payment is covered by
--                        strm_claim_payment + task_claim_autoclose (below).
--
-- The claim CDC stream at the bottom replaces the TRUNC(SYSDATE) - 1 flat-file
-- extract window used by NightlyExtract / export_oracle_to_stage.sh (section 8).
--------------------------------------------------------------------------------

USE SCHEMA hartford.claims;

--------------------------------------------------------------------------------
-- updated_ts maintenance for rows changed by statements that do not set it.
-- The task only touches rows whose updated_ts is older than the change, so its
-- own writes do not cause it to re-fire indefinitely.
--------------------------------------------------------------------------------
CREATE OR REPLACE STREAM hartford.claims.strm_customer
  ON TABLE hartford.claims.customer;

CREATE OR REPLACE TASK hartford.claims.task_customer_touch
  WAREHOUSE = CLAIMS_WH
  SCHEDULE  = '1 minute'
  WHEN SYSTEM$STREAM_HAS_DATA('hartford.claims.strm_customer')
AS
UPDATE hartford.claims.customer tgt
   SET updated_ts = CURRENT_TIMESTAMP()
  FROM (
        SELECT customer_id, MAX(updated_ts) AS changed_ts
          FROM hartford.claims.strm_customer
         WHERE METADATA$ACTION = 'INSERT'
           AND METADATA$ISUPDATE = TRUE
         GROUP BY customer_id
       ) chg
 WHERE tgt.customer_id = chg.customer_id
   AND tgt.updated_ts <= chg.changed_ts;

--------------------------------------------------------------------------------
-- Auto-close claims once payments meet the reserve. sp_post_payment already
-- does this inline; this task covers payments loaded by the pipeline (COPY INTO
-- / Snowpipe) that bypass the procedure.
--------------------------------------------------------------------------------
CREATE OR REPLACE STREAM hartford.claims.strm_claim_payment
  ON TABLE hartford.claims.claim_payment;

CREATE OR REPLACE TASK hartford.claims.task_claim_autoclose
  WAREHOUSE = CLAIMS_WH
  SCHEDULE  = '5 minute'
  WHEN SYSTEM$STREAM_HAS_DATA('hartford.claims.strm_claim_payment')
AS
MERGE INTO hartford.claims.claim tgt
USING (
        SELECT claim_id, SUM(amount) AS new_amount
          FROM hartford.claims.strm_claim_payment
         WHERE METADATA$ACTION = 'INSERT'
         GROUP BY claim_id
      ) src
   ON tgt.claim_id = src.claim_id
 WHEN MATCHED THEN
   UPDATE SET tgt.paid_amount = tgt.paid_amount + src.new_amount,
              tgt.status = IFF(tgt.paid_amount + src.new_amount >= tgt.reserve_amount,
                               'CLOSED', tgt.status);

--------------------------------------------------------------------------------
-- CDC stream feeding the downstream warehouse. Consumers read this instead of
-- filtering on "reported_date >= TRUNC(SYSDATE) - 1".
--------------------------------------------------------------------------------
CREATE OR REPLACE STREAM hartford.claims.strm_claim_cdc
  ON TABLE hartford.claims.claim;

CREATE OR REPLACE TASK hartford.claims.task_claim_export
  WAREHOUSE = CLAIMS_WH
  SCHEDULE  = 'USING CRON 0 2 * * * America/New_York'
  WHEN SYSTEM$STREAM_HAS_DATA('hartford.claims.strm_claim_cdc')
AS
COPY INTO @hartford.claims.claims_stage/claim_cdc/
FROM (
      SELECT claim_id, claim_number, policy_id,
             TO_VARCHAR(reported_date, 'YYYY-MM-DD HH24:MI:SS') AS reported,
             status, reserve_amount, paid_amount
        FROM hartford.claims.strm_claim_cdc
       WHERE METADATA$ACTION = 'INSERT'
     )
FILE_FORMAT = (FORMAT_NAME = hartford.claims.ff_claims_psv)
HEADER = TRUE
OVERWRITE = FALSE;

ALTER TASK hartford.claims.task_customer_touch RESUME;
ALTER TASK hartford.claims.task_claim_autoclose RESUME;
ALTER TASK hartford.claims.task_claim_export RESUME;
