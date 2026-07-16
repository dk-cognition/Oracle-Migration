--------------------------------------------------------------------------------
-- The Hartford - Claims Data Store
-- Streams + Tasks: the Snowflake replacement for Oracle row triggers and
-- materialized-view fast-refresh semantics. See docs/MIGRATION.md section 3.
--
-- What the Oracle triggers did and where it now lives:
--   * trg_customer_biu / trg_policy_bi PK assignment -> AUTOINCREMENT columns
--     in 01_schema.sql (no trigger needed).
--   * created_ts / updated_ts defaults -> column DEFAULT CURRENT_TIMESTAMP().
--   * "On update" updated_ts: Snowflake has no row triggers. The PREFERRED
--     approach is for the writing statement to set it (see the customer_upsert
--     MERGE in src/main/resources/sql/reports.sql, which sets
--     updated_ts = CURRENT_TIMESTAMP()). The Stream + Task below shows the CDC
--     pattern for downstream propagation when writers cannot be changed.
--------------------------------------------------------------------------------

USE SCHEMA hartford.hartford;

--------------------------------------------------------------------------------
-- Change-data-capture stream over CUSTOMER (replaces the row-trigger hook).
--------------------------------------------------------------------------------
CREATE OR REPLACE STREAM hartford.customer_changes ON TABLE hartford.customer;

--------------------------------------------------------------------------------
-- Downstream audit feed maintained by the task (CDC target). Kept separate from
-- CUSTOMER so the task does not recursively re-trigger its own stream.
--------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS hartford.customer_audit (
  customer_id  NUMBER(12)   NOT NULL,
  change_type  VARCHAR(16)  NOT NULL,   -- INSERT / UPDATE / DELETE
  changed_ts   TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP() NOT NULL,
  first_name   VARCHAR(60),
  last_name    VARCHAR(60),
  email        VARCHAR(120)
);

--------------------------------------------------------------------------------
-- Task: drains the stream on a schedule and appends audit rows. Runs only when
-- the stream has data (SYSTEM$STREAM_HAS_DATA). Resume with ALTER TASK ... RESUME.
--------------------------------------------------------------------------------
CREATE OR REPLACE TASK hartford.customer_audit_task
  WAREHOUSE = CLAIMS_WH
  SCHEDULE = '5 MINUTE'
  WHEN SYSTEM$STREAM_HAS_DATA('hartford.customer_changes')
AS
  INSERT INTO hartford.customer_audit (customer_id, change_type, first_name, last_name, email)
  SELECT customer_id,
         CASE
           WHEN METADATA$ACTION = 'DELETE' THEN 'DELETE'
           WHEN METADATA$ISUPDATE          THEN 'UPDATE'
           ELSE 'INSERT'
         END,
         first_name,
         last_name,
         email
    FROM hartford.customer_changes
   WHERE NOT (METADATA$ACTION = 'DELETE' AND METADATA$ISUPDATE);

-- ALTER TASK hartford.customer_audit_task RESUME;
