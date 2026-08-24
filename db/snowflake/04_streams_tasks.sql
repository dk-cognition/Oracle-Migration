--------------------------------------------------------------------------------
-- The Hartford - Claims Data Store
-- Stream and task replacement for the customer updated_ts trigger.
--------------------------------------------------------------------------------

USE SCHEMA hartford;

-- Inserts are handled by column defaults. Writers should ideally set updated_ts
-- directly; this task covers changed rows that need the old trigger semantics.
CREATE OR REPLACE STREAM hartford.customer_changes
  ON TABLE hartford.customer;

CREATE OR REPLACE TASK hartford.customer_updated_ts_task
  WAREHOUSE = CLAIMS_WH
  SCHEDULE = '1 MINUTE'
  WHEN SYSTEM$STREAM_HAS_DATA('hartford.customer_changes')
AS
  UPDATE hartford.customer
     SET updated_ts = CURRENT_TIMESTAMP()
   WHERE customer_id IN (
     SELECT customer_id
       FROM hartford.customer_changes
      WHERE METADATA$ACTION IN ('INSERT', 'UPDATE')
   );
