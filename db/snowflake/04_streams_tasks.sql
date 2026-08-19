--------------------------------------------------------------------------------
-- The Hartford - Claims Data Store
-- Streams + Tasks: the replacement for Oracle row-level triggers and for the
-- flat-file nightly extract delta window.
--
-- Migration notes (see docs/MIGRATION.md):
--   * trg_policy_bi (PK from sequence) is fully covered by the column DEFAULT
--     in 01_schema.sql -- nothing needed here.
--   * trg_customer_biu also assigned the PK and created_ts (column DEFAULTs
--     now), plus an "on update" updated_ts. Snowflake cannot fire per-row on
--     update, so a Stream over customer feeds a Task that stamps updated_ts for
--     rows changed by writers that did not set it themselves.
--   * The nightly extract's `reported_date >= TRUNC(SYSDATE) - 1` scan is
--     replaced by a Stream on claim: consumers read only the actual CDC delta.
--------------------------------------------------------------------------------

USE SCHEMA hartford.claims;

--------------------------------------------------------------------------------
-- updated_ts maintenance (former trg_customer_biu "on update" behaviour)
--------------------------------------------------------------------------------
CREATE OR REPLACE STREAM strm_customer_dml ON TABLE customer;

CREATE OR REPLACE TASK tsk_customer_updated_ts
  WAREHOUSE = CLAIMS_WH
  SCHEDULE = '1 MINUTE'
  WHEN SYSTEM$STREAM_HAS_DATA('strm_customer_dml')
AS
  MERGE INTO customer tgt
  USING (
    SELECT customer_id, MAX(updated_ts) AS prev_updated_ts
      FROM strm_customer_dml
     WHERE METADATA$ACTION = 'INSERT'
       AND METADATA$ISUPDATE = TRUE
     GROUP BY customer_id
  ) src
     ON tgt.customer_id = src.customer_id
   WHEN MATCHED AND tgt.updated_ts = src.prev_updated_ts THEN
     UPDATE SET tgt.updated_ts = CURRENT_TIMESTAMP();

ALTER TASK tsk_customer_updated_ts RESUME;

--------------------------------------------------------------------------------
-- Claim CDC feed for the warehouse (former NightlyExtract delta window)
--------------------------------------------------------------------------------
CREATE OR REPLACE STREAM strm_claim_changes ON TABLE claim;

-- Landing table the downstream warehouse reads; the Task drains the stream so
-- each change is delivered exactly once instead of re-scanning a date window.
CREATE OR REPLACE TABLE claim_change_feed (
  claim_id       NUMBER(12),
  claim_number   VARCHAR(24),
  policy_id      NUMBER(12),
  reported_date  TIMESTAMP_NTZ,
  status         VARCHAR(16),
  reserve_amount NUMBER(14,2),
  paid_amount    NUMBER(14,2),
  change_action  VARCHAR(16),
  captured_ts    TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE TASK tsk_claim_cdc
  WAREHOUSE = CLAIMS_WH
  SCHEDULE = '5 MINUTE'
  WHEN SYSTEM$STREAM_HAS_DATA('strm_claim_changes')
AS
  INSERT INTO claim_change_feed (
    claim_id, claim_number, policy_id, reported_date, status,
    reserve_amount, paid_amount, change_action
  )
  SELECT claim_id, claim_number, policy_id, reported_date, status,
         reserve_amount, paid_amount,
         CASE WHEN METADATA$ACTION = 'INSERT' AND METADATA$ISUPDATE THEN 'UPDATE'
              ELSE METADATA$ACTION
         END
    FROM strm_claim_changes;

ALTER TASK tsk_claim_cdc RESUME;
