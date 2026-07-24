--------------------------------------------------------------------------------
-- The Hartford - Claims Data Store
-- Streams + Tasks: the Snowflake replacement for Oracle row-level triggers.
--
-- trg_customer_biu did two things:
--   1. PK default from seq_customer_id  -> column DEFAULT in 01_schema.sql
--   2. updated_ts maintenance on UPDATE -> the stream + task below
-- trg_policy_bi (PK default)            -> column DEFAULT in 01_schema.sql
--------------------------------------------------------------------------------

USE SCHEMA hartford.claims;

-- Captures DML on customer so the task only touches changed rows.
CREATE OR REPLACE STREAM strm_customer_changes ON TABLE customer;

-- Stamps updated_ts for rows changed by statements that did not set it.
CREATE OR REPLACE TASK task_customer_updated_ts
  WAREHOUSE = CLAIMS_WH
  SCHEDULE = '5 MINUTE'
  WHEN SYSTEM$STREAM_HAS_DATA('strm_customer_changes')
AS
  MERGE INTO customer tgt
  USING (
    SELECT customer_id
      FROM strm_customer_changes
     WHERE METADATA$ACTION = 'INSERT'
       AND METADATA$ISUPDATE = TRUE
  ) src
     ON tgt.customer_id = src.customer_id
   WHEN MATCHED THEN UPDATE SET tgt.updated_ts = CURRENT_TIMESTAMP();

ALTER TASK task_customer_updated_ts RESUME;

--------------------------------------------------------------------------------
-- CDC feed for the nightly warehouse extract (replaces TRUNC(SYSDATE) - 1).
--------------------------------------------------------------------------------
CREATE OR REPLACE STREAM strm_claim_changes ON TABLE claim;
