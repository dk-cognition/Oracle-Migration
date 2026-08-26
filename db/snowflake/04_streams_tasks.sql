--------------------------------------------------------------------------------
-- The Hartford - Claims Data Store
-- Streams + Tasks replacing Oracle row-level trigger semantics
-- (db/oracle/02_packages.sql: trg_customer_biu, trg_policy_bi).
--
-- Snowflake has no row-level triggers:
--   * INSERT-time behavior (PK from sequence, created_ts/updated_ts stamps)
--     is handled by column DEFAULTs in 01_schema.sql.
--   * UPDATE-time behavior (trg_customer_biu refreshing updated_ts on every
--     UPDATE) is re-expressed here as a Stream + serverless Task: the stream
--     captures customer changes and the task touches updated_ts for rows the
--     writing statement did not stamp itself.
--------------------------------------------------------------------------------

USE SCHEMA hartford;

--------------------------------------------------------------------------------
-- Stream: capture customer DML (CDC) for the updated_ts maintenance task.
--------------------------------------------------------------------------------
CREATE OR REPLACE STREAM hartford.st_customer_changes
  ON TABLE hartford.customer;

--------------------------------------------------------------------------------
-- Task: refresh updated_ts for customers changed since the last run.
-- Runs every 5 minutes, but only when the stream has captured data.
-- The pre-image ('DELETE') and post-image ('INSERT') rows of each UPDATE are
-- joined so that rows whose writer (or this task) already stamped updated_ts
-- are skipped — otherwise the task would re-trigger on its own MERGE.
--------------------------------------------------------------------------------
CREATE OR REPLACE TASK hartford.tk_touch_customer_updated_ts
  SCHEDULE = '5 MINUTE'
  WHEN SYSTEM$STREAM_HAS_DATA('HARTFORD.ST_CUSTOMER_CHANGES')
AS
  MERGE INTO hartford.customer tgt
  USING (
    SELECT DISTINCT post.customer_id
      FROM hartford.st_customer_changes post
      JOIN hartford.st_customer_changes pre
        ON post.METADATA$ROW_ID = pre.METADATA$ROW_ID
       AND pre.METADATA$ACTION  = 'DELETE'
       AND pre.METADATA$ISUPDATE
     WHERE post.METADATA$ACTION = 'INSERT'
       AND post.METADATA$ISUPDATE
       AND post.updated_ts = pre.updated_ts   -- writer did not stamp updated_ts
  ) src
     ON tgt.customer_id = src.customer_id
   WHEN MATCHED THEN
     UPDATE SET tgt.updated_ts = CURRENT_TIMESTAMP();

-- Tasks are created suspended; enable explicitly.
ALTER TASK hartford.tk_touch_customer_updated_ts RESUME;
